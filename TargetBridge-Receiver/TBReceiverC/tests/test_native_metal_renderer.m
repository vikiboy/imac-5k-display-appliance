#import "tb_native_metal_renderer.h"

#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include "tb_dpcm.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int headless_presentation_mode(void) {
    const char *value = getenv("TB_TEST_HEADLESS_PRESENTATION");
    return value && strcmp(value, "1") == 0;
}

static int wait_for_completions(void *renderer, uint64_t target) {
    const CFTimeInterval deadline = CACurrentMediaTime() + 3.0;
    struct tb_native_metal_stats stats;
    do {
        tb_native_metal_get_stats(renderer, &stats);
        if (stats.completed_frames >= target) return 1;
        [[NSRunLoop currentRunLoop]
            runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    } while (CACurrentMediaTime() < deadline);
    return 0;
}

static int wait_for_presentation_callbacks(void *renderer,
                                           uint64_t epoch,
                                           uint64_t target) {
    const CFTimeInterval deadline = CACurrentMediaTime() + 3.0;
    struct tb_native_metal_stats stats;
    do {
        tb_native_metal_get_stats(renderer, &stats);
        if (stats.presentation_epoch == epoch) {
            const int state = tb_native_metal_presentation_resolution_state(
                target,
                stats.presentation_epoch_presented_frames,
                stats.presentation_epoch_dropped_frames);
            if (state == TB_NATIVE_METAL_PRESENTATION_DRAINED) return 1;
            if (state == TB_NATIVE_METAL_PRESENTATION_INVARIANT) {
                fprintf(stderr,
                        "native Metal renderer test: presentation callback "
                        "invariant epoch=%llu target=%llu presented=%llu "
                        "dropped=%llu\n",
                        (unsigned long long)epoch,
                        (unsigned long long)target,
                        (unsigned long long)
                            stats.presentation_epoch_presented_frames,
                        (unsigned long long)
                            stats.presentation_epoch_dropped_frames);
                return 0;
            }
        }
        [[NSRunLoop currentRunLoop]
            runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    } while (CACurrentMediaTime() < deadline);
    fprintf(stderr,
            "native Metal renderer test: presentation callback timeout "
            "epoch=%llu target=%llu current=%llu presented=%llu dropped=%llu "
            "submitted=%llu completed=%llu\n",
            (unsigned long long)epoch,
            (unsigned long long)target,
            (unsigned long long)stats.presentation_epoch,
            (unsigned long long)stats.presentation_epoch_presented_frames,
            (unsigned long long)stats.presentation_epoch_dropped_frames,
            (unsigned long long)stats.submitted_frames,
            (unsigned long long)stats.completed_frames);
    return 0;
}

static int exercise_dpcm_upload_growth_policy(void) {
    const size_t limit = 1024 * 1024;
    const size_t first = tb_native_metal_dpcm_next_upload_capacity(
        0, 100000, limit);
    const size_t grown = tb_native_metal_dpcm_next_upload_capacity(
        first, first + 1, limit);
    const size_t reused = tb_native_metal_dpcm_next_upload_capacity(
        grown, first, limit);
    const size_t capped = tb_native_metal_dpcm_next_upload_capacity(
        grown, limit, limit);
    const size_t overflowSafe = tb_native_metal_dpcm_next_upload_capacity(
        SIZE_MAX - 8, SIZE_MAX - 4, SIZE_MAX);

    const int ok =
        first == 100000 &&
        grown > first + 1 && grown <= limit &&
        reused == grown &&
        capped == limit &&
        overflowSafe == SIZE_MAX &&
        tb_native_metal_dpcm_next_upload_capacity(0, 0, limit) == 0 &&
        tb_native_metal_dpcm_next_upload_capacity(0, limit + 1, limit) == 0 &&
        tb_native_metal_dpcm_next_upload_capacity(limit + 1, 1, limit) == 0;
    if (!ok) {
        fprintf(stderr,
                "native Metal renderer test: DPCM upload growth policy mismatch\n");
    }
    return ok;
}

static int exercise_terminal_completion_failure(int completionPath) {
    void *renderer = tb_native_metal_create();
    if (!renderer) {
        fprintf(stderr,
                "native Metal renderer test: terminal-latch renderer unavailable\n");
        return 0;
    }

    struct tb_native_metal_stats before;
    tb_native_metal_get_stats(renderer, &before);
    const int dpcmInitiallySupported =
        tb_native_metal_supports_dpcm(renderer);
    int ok =
        tb_native_metal_test_has_terminal_gpu_error(renderer) == 0 &&
        tb_native_metal_test_render_admission_result(renderer) == 1 &&
        tb_native_metal_test_record_completion_failure(
            renderer, completionPath) == 0;

    struct tb_native_metal_stats after;
    tb_native_metal_get_stats(renderer, &after);
    uint8_t y[4] = {16, 16, 16, 16};
    uint8_t uv[2] = {128, 128};
    const uint8_t dpcmPlaceholder = 0;
    if (ok) {
        ok = dpcmInitiallySupported == 1 &&
             tb_native_metal_test_has_terminal_gpu_error(renderer) == 1 &&
             tb_native_metal_test_render_admission_result(renderer) == -1 &&
             tb_native_metal_supports_dpcm(renderer) == 0 &&
             after.completed_frames == before.completed_frames + 1 &&
             after.gpu_error_frames == before.gpu_error_frames + 1 &&
             tb_native_metal_render_nv12_planes(
                 renderer, y, 2, uv, 2, 2, 2,
                 0, 0, 2, 2, 0, 0, 0) == -1 &&
             tb_native_metal_render_dpcm(
                 renderer, &dpcmPlaceholder, sizeof(dpcmPlaceholder),
                 0, 0, 1, 1, 0, 0, 0) == -1 &&
             tb_native_metal_render_cursor(
                 renderer, 0, 0, 2, 2, 0, 0, 0) == -1;
    }

    tb_native_metal_destroy(renderer);
    if (!ok) {
        fprintf(stderr,
                "native Metal renderer test: %s completion did not latch terminal admission\n",
                completionPath == TB_NATIVE_METAL_TEST_COMPLETION_DPCM
                    ? "DPCM"
                    : "NV12");
    }
    return ok;
}

static int exercise_bounded_teardown_drain(void) {
    void *renderer = tb_native_metal_create();
    if (!renderer) {
        fprintf(stderr,
                "native Metal renderer test: teardown renderer unavailable\n");
        return 0;
    }

    int claimed = 0;
    int ok = tb_native_metal_test_drain_with_timeout(
        renderer, 100 * NSEC_PER_MSEC) == 0;

    /* A successful drain must restore all three semaphore permits. */
    for (int slot = 0; ok && slot < 3; slot++) {
        if (tb_native_metal_test_claim_inflight_slot(renderer) != 0) {
            ok = 0;
            break;
        }
        claimed++;
    }
    if (ok && tb_native_metal_test_claim_inflight_slot(renderer) != -1) {
        ok = 0;
    }
    while (claimed > 0) {
        if (tb_native_metal_test_release_inflight_slot(renderer) != 0) ok = 0;
        claimed--;
    }

    /* One permanently claimed slot models a committed command whose
     * completion handler never runs. The whole drain gets one 10 ms deadline,
     * then the renderer is quarantined and refuses new work. */
    if (ok && tb_native_metal_test_claim_inflight_slot(renderer) == 0) {
        claimed = 1;
        const CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
        const int drainResult = tb_native_metal_test_drain_with_timeout(
            renderer, 10 * NSEC_PER_MSEC);
        const CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - started;
        ok = drainResult == -1 && elapsed < 0.5 &&
             tb_native_metal_test_is_quarantined(renderer) == 1 &&
             tb_native_metal_supports_dpcm(renderer) == 0;
    } else {
        ok = 0;
    }

    while (claimed > 0) {
        if (tb_native_metal_test_release_inflight_slot(renderer) != 0) ok = 0;
        claimed--;
    }
    tb_native_metal_destroy(renderer);
    if (!ok) {
        fprintf(stderr,
                "native Metal renderer test: bounded teardown drain failed\n");
    }
    return ok;
}

static int exercise_hardware_presentation_timeline(void) {
    void *renderer = tb_native_metal_create();
    if (!renderer) {
        fprintf(stderr,
                "native Metal renderer test: cadence renderer unavailable\n");
        return 0;
    }
    const uint64_t oldEpoch =
        tb_native_metal_test_begin_presentation_epoch(renderer);
    const uint64_t currentEpoch =
        tb_native_metal_test_begin_presentation_epoch(renderer);
    tb_native_metal_test_record_presented_time(renderer, currentEpoch, 10.000);
    tb_native_metal_test_record_presented_time(renderer, currentEpoch, 10.016);
    tb_native_metal_test_record_presented_time(renderer, currentEpoch, 10.010);
    /* Apple reports zero when a drawable was not presented. Invalid values
     * must be drops, never fabricated presentation timestamps. */
    tb_native_metal_test_record_presented_time(renderer, currentEpoch, 0.0);
    tb_native_metal_test_record_presented_time(renderer, currentEpoch, NAN);
    tb_native_metal_test_record_presented_time(renderer, currentEpoch, -1.0);
    tb_native_metal_test_record_presented_time(renderer, currentEpoch, INFINITY);
    /* A delayed callback from an earlier session must never contaminate the
     * current epoch's cadence statistics. */
    tb_native_metal_test_record_presented_time(renderer, oldEpoch, 10.032);
    tb_native_metal_test_record_presented_time(renderer, oldEpoch, 0.0);

    struct tb_native_metal_stats stats;
    tb_native_metal_get_stats(renderer, &stats);
    struct tb_native_metal_stats runtimeStats;
    tb_native_metal_get_runtime_stats(renderer, &runtimeStats);
    uint64_t presentationGapSamples = 0;
    for (size_t index = 0;
         index < TB_NATIVE_METAL_TIMING_BUCKETS;
         index++) {
        presentationGapSamples +=
            stats.presentation_epoch_gap_histogram[index];
    }
    int ok = oldEpoch != 0 && currentEpoch == oldEpoch + 1 &&
        stats.presentation_epoch == currentEpoch &&
        stats.presentation_epoch_presented_frames == 3 &&
        stats.presentation_epoch_dropped_frames == 4 &&
        stats.presentation_dropped_frames == 5 &&
        stats.presentation_epoch_out_of_order_callbacks == 1 &&
        presentationGapSamples == 1 &&
        fabs(stats.presentation_epoch_gap_ms_max - 16.0) < 0.000001 &&
        fabs(stats.presentation_epoch_first_time - 10.000) < 0.000001 &&
        fabs(stats.presentation_epoch_last_time - 10.016) < 0.000001 &&
        runtimeStats.presentation_epoch == stats.presentation_epoch &&
        runtimeStats.presented_frames == stats.presented_frames &&
        runtimeStats.presentation_dropped_frames ==
            stats.presentation_dropped_frames &&
        runtimeStats.device_current_allocated_bytes == 0 &&
        runtimeStats.device_recommended_working_set_bytes == 0;

    const uint64_t droppedOnlyEpoch =
        tb_native_metal_test_begin_presentation_epoch(renderer);
    tb_native_metal_test_record_presented_time(renderer, droppedOnlyEpoch, 0.0);
    struct tb_native_metal_stats droppedOnlyStats;
    tb_native_metal_get_stats(renderer, &droppedOnlyStats);
    ok = ok && droppedOnlyEpoch == currentEpoch + 1 &&
        droppedOnlyStats.last_presented_epoch == currentEpoch &&
        droppedOnlyStats.presentation_epoch_presented_frames == 0 &&
        droppedOnlyStats.presentation_epoch_dropped_frames == 1 &&
        droppedOnlyStats.presentation_epoch_first_time == 0.0 &&
        droppedOnlyStats.presentation_epoch_last_time == 0.0;
    tb_native_metal_destroy(renderer);
    if (!ok) {
        fprintf(stderr,
                "native Metal renderer test: hardware timeline isolation/order failed\n");
    }
    return ok;
}

static int exercise_presentation_resolution_state(void) {
    const int ok =
        tb_native_metal_presentation_resolution_state(0, 0, 0) ==
            TB_NATIVE_METAL_PRESENTATION_DRAINED &&
        tb_native_metal_presentation_resolution_state(3, 2, 1) ==
            TB_NATIVE_METAL_PRESENTATION_DRAINED &&
        tb_native_metal_presentation_resolution_state(3, 2, 0) ==
            TB_NATIVE_METAL_PRESENTATION_PENDING &&
        tb_native_metal_presentation_resolution_state(3, 3, 1) ==
            TB_NATIVE_METAL_PRESENTATION_INVARIANT &&
        tb_native_metal_presentation_resolution_state(
            UINT64_MAX, UINT64_MAX - 1, 1) ==
            TB_NATIVE_METAL_PRESENTATION_DRAINED &&
        tb_native_metal_presentation_resolution_state(
            UINT64_MAX, UINT64_MAX, 1) ==
            TB_NATIVE_METAL_PRESENTATION_INVARIANT;
    if (!ok) {
        fprintf(stderr,
                "native Metal renderer test: presentation resolution state failed\n");
    }
    return ok;
}

static int exercise_display_sync_policy(void) {
    const int ok =
        tb_native_metal_test_display_sync_enabled_for_value(NULL) == 1 &&
        tb_native_metal_test_display_sync_enabled_for_value("") == 1 &&
        tb_native_metal_test_display_sync_enabled_for_value("1") == 1 &&
        tb_native_metal_test_display_sync_enabled_for_value("false") == 1 &&
        tb_native_metal_test_display_sync_enabled_for_value("00") == 1 &&
        tb_native_metal_test_display_sync_enabled_for_value("0") == 0;
    if (!ok) {
        fprintf(stderr,
                "native Metal renderer test: display-sync policy failed\n");
    }
    return ok;
}

static int exercise_dpcm_fixture(void *renderer, int width, int height) {
    if (!tb_native_metal_supports_dpcm(renderer)) {
        fprintf(stderr,
                "native Metal renderer test: DPCM pipeline unavailable\n");
        return 0;
    }

    if (width <= 0 || height <= 0) {
        fprintf(stderr,
                "native Metal renderer test: invalid DPCM drawable fixture size\n");
        return 0;
    }
    const int stride = width * 4;
    const size_t frameBytes = (size_t)stride * height;
    const size_t blobCapacity = tb_dpcm_max_size(width, height);
    uint8_t *frame = (uint8_t *)malloc(frameBytes);
    uint8_t *blob = (uint8_t *)malloc(blobCapacity);
    if (!frame || !blob) {
        free(frame);
        free(blob);
        return 0;
    }

    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            uint8_t *pixel = frame + (size_t)y * stride + (size_t)x * 4;
            pixel[0] = (uint8_t)((x * 3 + y) & 0xff);
            pixel[1] = (uint8_t)((x + y * 5) & 0xff);
            pixel[2] = (uint8_t)((x ^ y) & 0xff);
            pixel[3] = 0xff;
        }
    }

    const size_t blobLength = tb_dpcm_encode(
        frame, stride, width, height, 0, blob, blobCapacity);
    struct tb_native_metal_stats baseline;
    tb_native_metal_get_stats(renderer, &baseline);
    enum { repeatedFrames = 192 };
    int submitted = 0;
    for (int index = 0; blobLength > 0 && index < repeatedFrames; index++) {
        const int submitResult = tb_native_metal_render_dpcm(
            renderer, blob, blobLength,
            index, index, width, height, 0, 0, 0);
        if (submitResult != 1) break;
        submitted++;
        /* Keep this deterministic on both integrated and discrete GPUs: each
         * iteration completes before rotating to the next upload-ring slot. */
        if (index + 1 < repeatedFrames &&
            !wait_for_completions(
                renderer, baseline.completed_frames + (uint64_t)submitted)) {
            break;
        }
    }

    /* The final submitted command must own its staging resources before the
     * caller overwrites and frees the source blob. */
    memset(blob, 0xa5, blobCapacity);
    free(blob);
    free(frame);

    if (submitted != repeatedFrames ||
        !wait_for_completions(
            renderer, baseline.completed_frames + (uint64_t)submitted)) {
        fprintf(stderr,
                "native Metal renderer test: DPCM fixture did not complete\n");
        return 0;
    }

    struct tb_native_metal_stats after;
    tb_native_metal_get_stats(renderer, &after);
    if (after.submitted_frames !=
            baseline.submitted_frames + (uint64_t)repeatedFrames ||
        after.completed_frames !=
            baseline.completed_frames + (uint64_t)repeatedFrames ||
        after.dpcm_upload_buffer_allocations -
                baseline.dpcm_upload_buffer_allocations != 3 ||
        after.dpcm_decoded_buffer_allocations -
                baseline.dpcm_decoded_buffer_allocations != 1 ||
        after.dpcm_texture_view_creations -
                baseline.dpcm_texture_view_creations != 1 ||
        after.dpcm_upload_capacity_bytes < 3 * blobLength ||
        after.dpcm_decoded_capacity_bytes < (uint64_t)frameBytes) {
        fprintf(stderr,
                "native Metal renderer test: DPCM reuse/accounting mismatch "
                "uploadAllocs=%llu decodedAllocs=%llu textureViews=%llu\n",
                (unsigned long long)(after.dpcm_upload_buffer_allocations -
                                     baseline.dpcm_upload_buffer_allocations),
                (unsigned long long)(after.dpcm_decoded_buffer_allocations -
                                     baseline.dpcm_decoded_buffer_allocations),
                (unsigned long long)(after.dpcm_texture_view_creations -
                                     baseline.dpcm_texture_view_creations));
        return 0;
    }

    const uint8_t malformed[] = {'N', 'O', 'P', 'E'};
    if (tb_native_metal_render_dpcm(
            renderer, malformed, sizeof(malformed),
            0, 0, 1, 1, 0, 0, 0) != -1) {
        fprintf(stderr,
                "native Metal renderer test: malformed DPCM accepted\n");
        return 0;
    }
    return 1;
}

static int exercise_dpcm_decoded_size_cap(void) {
    const int native5KAllowed =
        tb_native_metal_dpcm_dimensions_supported(5120, 2880);
    const int exact64MiBAllowed =
        tb_native_metal_dpcm_dimensions_supported(4096, 4096);
    const int oversizedRejected =
        !tb_native_metal_dpcm_dimensions_supported(8192, 8192);
    const int invalidRejected =
        !tb_native_metal_dpcm_dimensions_supported(0, 2880) &&
        !tb_native_metal_dpcm_dimensions_supported(5120, 0);
    if (!native5KAllowed || !exact64MiBAllowed ||
        !oversizedRejected || !invalidRejected) {
        fprintf(stderr,
                "native Metal renderer test: DPCM decoded-size cap mismatch\n");
        return 0;
    }
    return 1;
}

static int exercise_raw_staging(void *renderer) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 640, 360)
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.releasedWhenClosed = NO;
    window.alphaValue = 0.02;
    [window orderFront:nil];
    [window displayIfNeeded];
    [window.contentView displayIfNeeded];
    [CATransaction flush];
    [[NSRunLoop currentRunLoop]
        runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];

    /* Reproduce the appliance transition: idle hides Metal; session start
     * attaches it drawable behind an external opaque cover; a presented-frame
     * epoch, not mere GPU completion, authorizes removal of that cover. */
    tb_native_metal_set_visible(renderer, 0);
    const uint64_t presentationEpoch =
        tb_native_metal_begin_presentation_session(renderer);

    const int width = 640;
    const int height = 360;
    const int yStride = width + 32;
    const int uvStride = width + 64;
    uint8_t *y = (uint8_t *)malloc((size_t)yStride * height);
    uint8_t *uv = (uint8_t *)malloc((size_t)uvStride * (height / 2));
    int ok = y && uv && presentationEpoch > 0;
    if (ok) {
        memset(y, 0x55, (size_t)yStride * height);
        memset(uv, 0xaa, (size_t)uvStride * (height / 2));
    }

    struct tb_native_metal_stats baseline;
    tb_native_metal_get_stats(renderer, &baseline);
    int presentationSubmissions = 0;
    if (ok) {
        /* A live sender immediately supplies a bounded run of frames. Exercise
         * all three drawable/in-flight slots so WindowServer can legally skip
         * one drawable without making the presentation callback test flaky. */
        for (int frame = 0; frame < 3; frame++) {
            const int result = tb_native_metal_render_nv12_planes(
                renderer, y, yStride, uv, uvStride, width, height,
                10 + frame, 20 + frame, width, height, 1, 0, 0);
            if (result != 1) break;
            presentationSubmissions++;
        }
        /* The renderer must already own every staging copy when this returns. */
        memset(y, 0xee, (size_t)yStride * height);
        memset(uv, 0x11, (size_t)uvStride * (height / 2));
        ok = presentationSubmissions == 3 &&
             wait_for_completions(
                 renderer,
                 baseline.completed_frames +
                     (uint64_t)presentationSubmissions);
        if (ok && !headless_presentation_mode()) {
            ok = wait_for_presentation_callbacks(
                renderer,
                presentationEpoch,
                (uint64_t)presentationSubmissions);
        }
        if (!ok) {
            fprintf(stderr,
                    "native Metal renderer test: covered first frames failed "
                    "submitted=%d epoch=%llu baselineCompleted=%llu\n",
                    presentationSubmissions,
                    (unsigned long long)presentationEpoch,
                    (unsigned long long)baseline.completed_frames);
        }
    }

    struct tb_native_metal_stats afterFirst;
    tb_native_metal_get_stats(renderer, &afterFirst);
    if (ok) {
        const uint64_t epochPresented =
            afterFirst.presentation_epoch_presented_frames;
        const uint64_t epochDropped =
            afterFirst.presentation_epoch_dropped_frames;
        const int presentationStateValid = epochPresented > 0
            ? afterFirst.last_presented_epoch == presentationEpoch &&
                afterFirst.presentation_epoch_first_time > 0.0 &&
                afterFirst.presentation_epoch_last_time >=
                    afterFirst.presentation_epoch_first_time
            : (headless_presentation_mode() ||
               epochDropped == (uint64_t)presentationSubmissions) &&
                afterFirst.last_presented_epoch < presentationEpoch &&
                afterFirst.presentation_epoch_first_time == 0.0 &&
                afterFirst.presentation_epoch_last_time == 0.0;
        const int presentationCallbacksComplete =
            epochPresented + epochDropped ==
                (uint64_t)presentationSubmissions;
        const int presentationCallbacksBounded =
            epochPresented + epochDropped <=
                (uint64_t)presentationSubmissions;
        ok = afterFirst.raw_copy_samples ==
                 baseline.raw_copy_samples +
                     (uint64_t)presentationSubmissions &&
             afterFirst.submitted_frames ==
                 baseline.submitted_frames +
                     (uint64_t)presentationSubmissions &&
             afterFirst.presentation_epoch == presentationEpoch &&
             (headless_presentation_mode()
                  ? presentationCallbacksBounded
                  : presentationCallbacksComplete) &&
             afterFirst.presentation_dropped_frames -
                     baseline.presentation_dropped_frames == epochDropped &&
             presentationStateValid;
        if (!ok) {
            fprintf(stderr,
                    "native Metal renderer test: presented accounting mismatch "
                    "raw=%llu/%llu submitted=%llu/%llu presented=%llu/%llu "
                    "presentationDrops=%llu/%llu last=%llu epoch=%llu "
                    "epochPresented=%llu epochDropped=%llu "
                    "first=%.6f lastTime=%.6f\n",
                    (unsigned long long)afterFirst.raw_copy_samples,
                    (unsigned long long)baseline.raw_copy_samples,
                    (unsigned long long)afterFirst.submitted_frames,
                    (unsigned long long)baseline.submitted_frames,
                    (unsigned long long)afterFirst.presented_frames,
                    (unsigned long long)baseline.presented_frames,
                    (unsigned long long)afterFirst.presentation_dropped_frames,
                    (unsigned long long)baseline.presentation_dropped_frames,
                    (unsigned long long)afterFirst.last_presented_epoch,
                    (unsigned long long)presentationEpoch,
                    (unsigned long long)epochPresented,
                    (unsigned long long)epochDropped,
                    afterFirst.presentation_epoch_first_time,
                    afterFirst.presentation_epoch_last_time);
        }
    }

    /* Recreate the pool at another resolution, then return to the original. */
    const int largeWidth = 1280;
    const int largeHeight = 720;
    uint8_t *largeY = (uint8_t *)calloc(
        (size_t)largeWidth, (size_t)largeHeight);
    uint8_t *largeUV = (uint8_t *)calloc(
        (size_t)largeWidth, (size_t)largeHeight / 2);
    struct tb_native_metal_stats beforeRecreate;
    tb_native_metal_get_stats(renderer, &beforeRecreate);
    if (ok && largeY && largeUV) {
        const int smallResult1 = tb_native_metal_render_nv12_planes(
            renderer, y, yStride, uv, uvStride, width, height,
            0, 0, width, height, 0, 0, 0);
        const int largeResult = tb_native_metal_render_nv12_planes(
            renderer, largeY, largeWidth, largeUV, largeWidth,
            largeWidth, largeHeight, 0, 0, largeWidth, largeHeight, 0, 0, 0);
        const int smallResult2 = tb_native_metal_render_nv12_planes(
            renderer, y, yStride, uv, uvStride, width, height,
            0, 0, width, height, 0, 0, 0);
        /* Each resolution change releases its pool while the preceding command
         * is still in flight. Retained pixel buffers must keep those surfaces
         * alive after every source allocation is overwritten or freed. */
        memset(y, 0x22, (size_t)yStride * height);
        memset(uv, 0xdd, (size_t)uvStride * (height / 2));
        memset(largeY, 0x33, (size_t)largeWidth * largeHeight);
        memset(largeUV, 0xcc, (size_t)largeWidth * (largeHeight / 2));
        ok = smallResult1 == 1 && largeResult == 1 && smallResult2 == 1;
    } else {
        ok = 0;
    }
    free(largeY);
    free(largeUV);
    if (ok) {
        ok = wait_for_completions(renderer, beforeRecreate.completed_frames + 3);
    }

    /* A burst may submit or deliberately drop, but must never fail or leave an
     * attempt unaccounted for. */
    struct tb_native_metal_stats beforeBurst;
    tb_native_metal_get_stats(renderer, &beforeBurst);
    int burstSubmitted = 0;
    int burstDropped = 0;
    if (ok) {
        for (int attempt = 0; attempt < 12; attempt++) {
            const int result = tb_native_metal_render_nv12_planes(
                renderer, y, yStride, uv, uvStride, width, height,
                attempt, attempt, width, height, 0, 0, 0);
            if (result == 1) burstSubmitted++;
            else if (result == 0) burstDropped++;
            else ok = 0;
        }
    }
    if (ok) {
        ok = wait_for_completions(
            renderer, beforeBurst.completed_frames + (uint64_t)burstSubmitted);
    }
    struct tb_native_metal_stats afterBurst;
    tb_native_metal_get_stats(renderer, &afterBurst);
    if (ok) {
        ok = burstSubmitted + burstDropped == 12 &&
             afterBurst.submitted_frames - beforeBurst.submitted_frames ==
                 (uint64_t)burstSubmitted &&
             afterBurst.dropped_frames - beforeBurst.dropped_frames ==
                 (uint64_t)burstDropped &&
             afterBurst.raw_copy_samples - beforeBurst.raw_copy_samples == 12;
    }

    if (ok) {
        NSRect backingBounds = [window.contentView
            convertRectToBacking:window.contentView.bounds];
        ok = exercise_dpcm_fixture(
            renderer,
            (int)llround(backingBounds.size.width),
            (int)llround(backingBounds.size.height));
    }

    free(y);
    free(uv);
    [window close];
    if (!ok) {
        fprintf(stderr,
                "native Metal renderer test: RAW staging/lifetime exercise failed\n");
    }
    return ok;
}

int main(void) {
    @autoreleasepool {
        if (headless_presentation_mode()) {
            printf("native Metal renderer test: headless CI mode; hardware "
                   "presentation callbacks are not a release gate\n");
        }
        if (!exercise_dpcm_upload_growth_policy()) return 1;
        if (!exercise_dpcm_decoded_size_cap()) return 1;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            printf("native Metal renderer test: skipped (no Metal device)\n");
            return 0;
        }
        if (!exercise_terminal_completion_failure(
                TB_NATIVE_METAL_TEST_COMPLETION_NV12)) return 1;
        if (!exercise_terminal_completion_failure(
                TB_NATIVE_METAL_TEST_COMPLETION_DPCM)) return 1;
        if (!exercise_hardware_presentation_timeline()) return 1;
        if (!exercise_presentation_resolution_state()) return 1;
        if (!exercise_display_sync_policy()) return 1;

        void *renderer = tb_native_metal_create();
        if (!renderer) {
            fprintf(stderr,
                    "native Metal renderer test: device exists but renderer/shader creation failed\n");
            return 1;
        }
        CVPixelBufferRef pixelBuffer = NULL;
        CFDictionaryRef attributes = (__bridge CFDictionaryRef)@{
            (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        CVReturn status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            640,
            360,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes,
            &pixelBuffer);
        if (status != kCVReturnSuccess || !pixelBuffer) {
            fprintf(stderr, "native Metal renderer test: pixel buffer creation failed\n");
            tb_native_metal_destroy(renderer);
            return 1;
        }

        if (strcmp(tb_native_metal_pixel_buffer_color_space(pixelBuffer), "sRGB") != 0) {
            fprintf(stderr, "native Metal renderer test: untagged buffer must use sRGB\n");
            CVPixelBufferRelease(pixelBuffer);
            tb_native_metal_destroy(renderer);
            return 1;
        }
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_P3_D65,
            kCVAttachmentMode_ShouldPropagate);
        if (strcmp(tb_native_metal_pixel_buffer_color_space(pixelBuffer), "Display P3") != 0) {
            fprintf(stderr, "native Metal renderer test: P3 metadata not recognized\n");
            CVPixelBufferRelease(pixelBuffer);
            tb_native_metal_destroy(renderer);
            return 1;
        }
        uint8_t invalidPlane = 0;
        if (tb_native_metal_render_nv12_planes(
                renderer,
                &invalidPlane, 3, &invalidPlane, 3,
                3, 2, 0, 0, 3, 2, 0, 0, 0) != -1) {
            fprintf(stderr, "native Metal renderer test: invalid RAW geometry accepted\n");
            CVPixelBufferRelease(pixelBuffer);
            tb_native_metal_destroy(renderer);
            return 1;
        }
        if (!exercise_raw_staging(renderer)) {
            CVPixelBufferRelease(pixelBuffer);
            tb_native_metal_destroy(renderer);
            return 1;
        }

        CVPixelBufferRelease(pixelBuffer);
        tb_native_metal_destroy(renderer);
        if (!exercise_bounded_teardown_drain()) return 1;
        printf("native Metal renderer test: device=%s shader/pipeline passed\n",
               device.name.UTF8String ?: "unknown");
        return 0;
    }
}
