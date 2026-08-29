#import "renderer_policy.h"
#import "tb_native_metal_renderer.h"

#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static double histogram_percentile(
    const uint64_t histogram[TB_NATIVE_METAL_TIMING_BUCKETS],
    unsigned percentile) {
    uint64_t total = 0;
    for (size_t i = 0; i < TB_NATIVE_METAL_TIMING_BUCKETS; i++) {
        total += histogram[i];
    }
    if (total == 0) return 0.0;

    const uint64_t wanted = (total * percentile + 99) / 100;
    uint64_t cumulative = 0;
    for (size_t i = 0; i < TB_NATIVE_METAL_TIMING_BUCKETS; i++) {
        cumulative += histogram[i];
        if (cumulative >= wanted) {
            return (double)(i + 1) * TB_NATIVE_METAL_TIMING_BUCKET_MS;
        }
    }
    return (double)TB_NATIVE_METAL_TIMING_BUCKETS *
        TB_NATIVE_METAL_TIMING_BUCKET_MS;
}

static CVPixelBufferRef make_frame(size_t width, size_t height) {
    CVPixelBufferRef pixelBuffer = NULL;
    CFDictionaryRef attributes = (__bridge CFDictionaryRef)@{
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES
    };
    CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        attributes,
        &pixelBuffer);
    if (status != kCVReturnSuccess || !pixelBuffer) return NULL;

    if (CVPixelBufferLockBaseAddress(pixelBuffer, 0) == kCVReturnSuccess) {
        memset(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
               128,
               CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) *
                   CVPixelBufferGetHeightOfPlane(pixelBuffer, 0));
        memset(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1),
               128,
               CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) *
                   CVPixelBufferGetHeightOfPlane(pixelBuffer, 1));
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    }
    CVBufferSetAttachment(pixelBuffer,
                          kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_P3_D65,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixelBuffer,
                          kCVImageBufferTransferFunctionKey,
                          kCVImageBufferTransferFunction_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixelBuffer,
                          kCVImageBufferYCbCrMatrixKey,
                          kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                          kCVAttachmentMode_ShouldPropagate);
    return pixelBuffer;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        const int width = argc > 1 ? atoi(argv[1]) : 4096;
        const int height = argc > 2 ? atoi(argv[2]) : 2304;
        const int frameCount = argc > 3 ? atoi(argv[3]) : 180;
        const int targetFPS = argc > 4 ? atoi(argv[4]) : 60;
        const BOOL rawCopy = argc > 5 && strcmp(argv[5], "raw-copy") == 0;
        if (width <= 0 || height <= 0 || frameCount < 120 || targetFPS <= 0) {
            fprintf(stderr,
                    "usage: benchmark_native_metal_renderer "
                    "[width height frames>=120 fps [iosurface|raw-copy]]\n");
            return 64;
        }
        if (!MTLCreateSystemDefaultDevice()) {
            fprintf(stderr, "TB_METAL_BENCHMARK result=unavailable reason=no-metal-device\n");
            return 69;
        }

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        const CGFloat windowWidth = MAX(1.0, (CGFloat)width / 2.0);
        const CGFloat windowHeight = MAX(1.0, (CGFloat)height / 2.0);
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, windowWidth, windowHeight)
                      styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered
                          defer:NO];
        window.title = @"TargetBridge Metal Benchmark";
        /* Command-line AppKit harnesses own this window through ARC. Avoid the
         * legacy close-time self-release, which would otherwise release it a
         * second time when the autorelease pool drains. */
        window.releasedWhenClosed = NO;
        window.alphaValue = 0.02;
        [window orderFront:nil];
        [[NSRunLoop currentRunLoop]
            runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];

        CVPixelBufferRef pixelBuffer = make_frame((size_t)width, (size_t)height);
        void *renderer = tb_native_metal_create();
        if (!pixelBuffer || !renderer) {
            fprintf(stderr, "TB_METAL_BENCHMARK result=failed reason=setup\n");
            if (pixelBuffer) CVPixelBufferRelease(pixelBuffer);
            if (renderer) tb_native_metal_destroy(renderer);
            [window close];
            return 70;
        }

        const CFTimeInterval started = CACurrentMediaTime();
        const uint8_t *rawY = NULL;
        const uint8_t *rawUV = NULL;
        int rawYStride = 0;
        int rawUVStride = 0;
        if (rawCopy) {
            const CVReturn lockStatus = CVPixelBufferLockBaseAddress(
                pixelBuffer, kCVPixelBufferLock_ReadOnly);
            if (lockStatus != kCVReturnSuccess) {
                fprintf(stderr,
                        "TB_METAL_BENCHMARK result=failed reason=source-lock\n");
                CVPixelBufferRelease(pixelBuffer);
                tb_native_metal_destroy(renderer);
                [window close];
                return 71;
            }
            rawY = (const uint8_t *)
                CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
            rawUV = (const uint8_t *)
                CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
            rawYStride = (int)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
            rawUVStride = (int)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
            if (!rawY || !rawUV) {
                fprintf(stderr,
                        "TB_METAL_BENCHMARK result=failed reason=source-lock\n");
                CVPixelBufferUnlockBaseAddress(
                    pixelBuffer, kCVPixelBufferLock_ReadOnly);
                CVPixelBufferRelease(pixelBuffer);
                tb_native_metal_destroy(renderer);
                [window close];
                return 71;
            }
        }
        for (int frame = 0; frame < frameCount; frame++) {
            if (rawCopy) {
                (void)tb_native_metal_render_nv12_planes(
                    renderer,
                    rawY, rawYStride, rawUV, rawUVStride,
                    width, height,
                    (frame * 13) % width, (frame * 7) % height,
                    width, height, 1, 0, 0);
            } else {
                (void)tb_native_metal_render_nv12(
                    renderer,
                    pixelBuffer,
                    (frame * 13) % width,
                    (frame * 7) % height,
                    width,
                    height,
                    1,
                    0,
                    0);
            }
            const CFTimeInterval target = started +
                (CFTimeInterval)(frame + 1) / (CFTimeInterval)targetFPS;
            const CFTimeInterval delay = target - CACurrentMediaTime();
            if (delay > 0) {
                [[NSRunLoop currentRunLoop]
                    runUntilDate:[NSDate dateWithTimeIntervalSinceNow:delay]];
            }
        }
        if (rawCopy) {
            CVPixelBufferUnlockBaseAddress(pixelBuffer,
                                           kCVPixelBufferLock_ReadOnly);
        }

        struct tb_native_metal_stats stats;
        const CFTimeInterval completionDeadline = CACurrentMediaTime() + 3.0;
        do {
            tb_native_metal_get_stats(renderer, &stats);
            if (stats.completed_frames >= stats.submitted_frames) break;
            [[NSRunLoop currentRunLoop]
                runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        } while (CACurrentMediaTime() < completionDeadline);

        tb_native_metal_get_stats(renderer, &stats);
        const struct tb_renderer_health_sample sample = {
            stats.submitted_frames,
            stats.completed_frames,
            stats.dropped_frames,
            stats.gpu_time_ms_total
        };
        const struct tb_renderer_health_result health =
            tb_renderer_evaluate_health(&sample);
        const double elapsed = CACurrentMediaTime() - started;
        const char *decision = health.decision == TB_RENDERER_HEALTH_KEEP_METAL
            ? "metal"
            : health.decision == TB_RENDERER_HEALTH_FALLBACK_OPENGL
                ? "opengl"
                : "insufficient-sample";
        printf(
            "TB_METAL_BENCHMARK result=%s size=%dx%d requested=%d targetFPS=%d "
            "input=%s "
            "elapsed=%.3fs submitted=%llu completed=%llu gpuErrors=%llu dropped=%llu "
            "inflight=%llu inflightMax=%llu "
            "submitAvg=%.3fms submitP50=%.2fms submitP95=%.2fms "
            "submitP99=%.2fms submitMax=%.3fms "
            "gpuAvg=%.3fms gpuP50=%.2fms gpuP95=%.2fms gpuP99=%.2fms "
            "gpuMax=%.3fms drawableWaitAvg=%.3fms "
            "drawableWaitP50=%.2fms drawableWaitP95=%.2fms "
            "drawableWaitP99=%.2fms drawableWaitMax=%.3fms "
            "rawCopyAvg=%.3fms rawCopyP50=%.2fms rawCopyP95=%.2fms "
            "rawCopyP99=%.2fms rawCopyMax=%.3fms "
            "color=%s\n",
            decision,
            width,
            height,
            frameCount,
            targetFPS,
            rawCopy ? "raw-copy" : "iosurface",
            elapsed,
            (unsigned long long)stats.submitted_frames,
            (unsigned long long)stats.completed_frames,
            (unsigned long long)stats.gpu_error_frames,
            (unsigned long long)stats.dropped_frames,
            (unsigned long long)stats.inflight_frames,
            (unsigned long long)stats.inflight_frames_max,
            stats.submit_samples
                ? stats.submit_time_ms_total / (double)stats.submit_samples
                : 0.0,
            histogram_percentile(stats.submit_time_histogram, 50),
            histogram_percentile(stats.submit_time_histogram, 95),
            histogram_percentile(stats.submit_time_histogram, 99),
            stats.submit_time_ms_max,
            health.gpu_average_ms,
            histogram_percentile(stats.gpu_time_histogram, 50),
            histogram_percentile(stats.gpu_time_histogram, 95),
            histogram_percentile(stats.gpu_time_histogram, 99),
            stats.gpu_time_ms_max,
            stats.drawable_requests
                ? stats.drawable_wait_ms_total / (double)stats.drawable_requests
                : 0.0,
            histogram_percentile(stats.drawable_wait_histogram, 50),
            histogram_percentile(stats.drawable_wait_histogram, 95),
            histogram_percentile(stats.drawable_wait_histogram, 99),
            stats.drawable_wait_ms_max,
            stats.raw_copy_samples
                ? stats.raw_copy_time_ms_total / (double)stats.raw_copy_samples
                : 0.0,
            histogram_percentile(stats.raw_copy_time_histogram, 50),
            histogram_percentile(stats.raw_copy_time_histogram, 95),
            histogram_percentile(stats.raw_copy_time_histogram, 99),
            stats.raw_copy_time_ms_max,
            tb_native_metal_color_space_name(renderer));

        CVPixelBufferRelease(pixelBuffer);
        tb_native_metal_destroy(renderer);
        [window close];
        return health.decision == TB_RENDERER_HEALTH_KEEP_METAL &&
               stats.gpu_error_frames == 0 ? 0 : 2;
    }
}
