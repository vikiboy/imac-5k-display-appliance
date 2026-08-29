#import <Foundation/Foundation.h>

#include "tb_dpcm.h"
#include "tb_dpcm_gpu.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int g_checks;
static int g_failures;

#define CHECK(cond, msg) do {                                              \
    ++g_checks;                                                            \
    if (!(cond)) {                                                         \
        ++g_failures;                                                      \
        fprintf(stderr, "FAIL %s:%d - %s\n", __FILE__, __LINE__, (msg)); \
    }                                                                      \
} while (0)

enum { kWidth = 64, kBandHeight = 32, kBands = 2, kHeaderReserve = 5 };

struct completion_state {
    _Atomic int calls;
    _Atomic int failures;
    _Atomic int next_index;
};

static void completion(void *opaque, int ok, const tb_dpcm_gpu_band *band,
                       int index, int last) {
    struct completion_state *state = opaque;
    const int expected = atomic_fetch_add_explicit(&state->next_index, 1,
                                                   memory_order_relaxed);
    if (!ok || !band || index < 0 || index >= kBands ||
        index != expected || last != (index == kBands - 1) ||
        band->len <= kHeaderReserve) {
        atomic_fetch_add_explicit(&state->failures, 1, memory_order_relaxed);
    } else {
        struct tb_dpcm_info info;
        if (tb_dpcm_parse(band->blob + kHeaderReserve,
                          band->len - kHeaderReserve, &info) != 0 ||
            info.width != kWidth || info.height != kBandHeight) {
            atomic_fetch_add_explicit(&state->failures, 1, memory_order_relaxed);
        }
    }
    atomic_fetch_add_explicit(&state->calls, 1, memory_order_relaxed);
}

static uint8_t *make_frame(size_t *allocated_size) {
    const size_t page = (size_t)getpagesize();
    const size_t bytes = (size_t)kWidth * kBandHeight * kBands * 4;
    const size_t rounded = (bytes + page - 1) / page * page;
    void *allocation = NULL;
    if (posix_memalign(&allocation, page, rounded) != 0) return NULL;
    uint8_t *frame = allocation;
    for (int y = 0; y < kBandHeight * kBands; ++y) {
        for (int x = 0; x < kWidth; ++x) {
            uint8_t *p = frame + ((size_t)y * kWidth + x) * 4;
            p[0] = (uint8_t)(x * 3 + y);
            p[1] = (uint8_t)(x + y * 5);
            p[2] = (uint8_t)(x ^ y);
            p[3] = 0xff;
        }
    }
    *allocated_size = rounded;
    return frame;
}

static int submit(tb_dpcm_gpu *encoder, uint8_t *frame,
                  struct completion_state *state) {
    return tb_dpcm_gpu_encode_bands_async(
        encoder, frame, kWidth * 4, kWidth, kBandHeight, kBands, 0,
        kHeaderReserve, completion, state);
}

static void require_success(tb_dpcm_gpu *encoder, uint8_t *frame) {
    struct completion_state state;
    atomic_init(&state.calls, 0);
    atomic_init(&state.failures, 0);
    atomic_init(&state.next_index, 0);
    CHECK(submit(encoder, frame, &state) == 0, "valid submission accepted");
    tb_dpcm_gpu_drain(encoder);
    CHECK(!tb_dpcm_gpu_is_quarantined(encoder), "valid submission drains");
    CHECK(atomic_load_explicit(&state.calls, memory_order_relaxed) == kBands,
          "one callback per band");
    CHECK(atomic_load_explicit(&state.failures, memory_order_relaxed) == 0,
          "completed bands contain valid bounded blobs");
}

static void require_precommit_failure(tb_dpcm_gpu *encoder, uint8_t *frame,
                                      uint32_t failure, int band) {
    struct completion_state rejected;
    atomic_init(&rejected.calls, 0);
    atomic_init(&rejected.failures, 0);
    atomic_init(&rejected.next_index, 0);
    tb_dpcm_gpu_test_fail_resource(encoder, failure, band);
    CHECK(submit(encoder, frame, &rejected) == -1,
          "resource creation failure rejects synchronously");
    CHECK(atomic_load_explicit(&rejected.calls, memory_order_relaxed) == 0,
          "rejected submission has no callback");

    /* This also proves the rejected job returned its semaphore permit and did
     * not advance the job ring onto a still-running slot. */
    require_success(encoder, frame);
}

int main(void) {
    @autoreleasepool {
        size_t frame_size = 0;
        uint8_t *frame = make_frame(&frame_size);
        CHECK(frame != NULL && frame_size > 0, "page-aligned frame allocation");
        if (!frame) return 1;

        tb_dpcm_gpu *encoder = tb_dpcm_gpu_create();
        if (!encoder) {
            fprintf(stderr, "DPCM GPU lifecycle test skipped: Metal encoder unavailable\n");
            free(frame);
            return 0;
        }

        require_precommit_failure(encoder, frame,
                                  TB_DPCM_GPU_TEST_FAIL_COMMAND_BUFFER, 0);
        require_precommit_failure(encoder, frame,
                                  TB_DPCM_GPU_TEST_FAIL_BLIT_ENCODER, 0);
        require_precommit_failure(encoder, frame,
                                  TB_DPCM_GPU_TEST_FAIL_COMPUTE_ENCODER, 0);
        require_precommit_failure(encoder, frame,
                                  TB_DPCM_GPU_TEST_FAIL_JOB_BUFFER, 0);
        require_precommit_failure(encoder, frame,
                                  TB_DPCM_GPU_TEST_FAIL_SOURCE_BUFFER, 0);
        /* The key partial-submit regression: band zero is fully encoded but
         * must remain uncommitted when creating band one's resources fails. */
        require_precommit_failure(encoder, frame,
                                  TB_DPCM_GPU_TEST_FAIL_COMMAND_BUFFER, 1);

        CHECK(tb_dpcm_gpu_test_claim_slot(encoder) == 0,
              "test can model one permanently unresolved job");
        fprintf(stderr, "DPCM GPU lifecycle: expecting quarantine diagnostic\n");
        const CFAbsoluteTime before = CFAbsoluteTimeGetCurrent();
        CHECK(tb_dpcm_gpu_test_drain_with_timeout(encoder, 10 * NSEC_PER_MSEC) == -1,
              "bounded drain reports timeout");
        const CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - before;
        CHECK(elapsed < 0.5, "drain timeout is bounded");
        CHECK(tb_dpcm_gpu_is_quarantined(encoder),
              "timed-out encoder enters quarantine");

        struct completion_state quarantined;
        atomic_init(&quarantined.calls, 0);
        atomic_init(&quarantined.failures, 0);
        atomic_init(&quarantined.next_index, 0);
        CHECK(submit(encoder, frame, &quarantined) == -1,
              "quarantined encoder rejects future work");
        CHECK(atomic_load_explicit(&quarantined.calls, memory_order_relaxed) == 0,
              "quarantine rejection has no callback");

        /* Only tests synthesize a claimed slot without a real Metal command.
         * Restore it so this encoder can be destroyed without an intentional
         * quarantine leak under leak-checking test runners. */
        tb_dpcm_gpu_test_recover_claimed_slots(encoder);
        tb_dpcm_gpu_destroy(encoder);
        free(frame);
    }

    if (g_failures) {
        fprintf(stderr, "DPCM GPU lifecycle: %d/%d checks failed\n",
                g_failures, g_checks);
        return 1;
    }
    printf("DPCM GPU lifecycle: %d checks passed\n", g_checks);
    return 0;
}
