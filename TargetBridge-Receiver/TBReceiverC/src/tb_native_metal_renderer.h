/* Direct macOS Metal presentation for VideoToolbox NV12 pixel buffers. */

#ifndef TB_NATIVE_METAL_RENDERER_H
#define TB_NATIVE_METAL_RENDERER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Histograms retain 0.1 ms resolution through 51.2 ms. The final bucket is
 * saturating; the exact maximum alongside each histogram preserves outliers. */
#define TB_NATIVE_METAL_TIMING_BUCKETS 512
#define TB_NATIVE_METAL_TIMING_BUCKET_MS 0.1
#define TB_NATIVE_METAL_MAX_DPCM_DECODED_BYTES ((size_t)64 * 1024 * 1024)
/* A negative result reserved for transient panel/window geometry. The caller
 * should close the current session and retry without changing capabilities. */
#define TB_NATIVE_METAL_RENDER_TRANSIENT_RETRY (-2)

struct tb_native_metal_stats {
    uint64_t submitted_frames;
    uint64_t completed_frames;
    uint64_t presented_frames;
    uint64_t presentation_epoch;
    uint64_t last_presented_epoch;
    uint64_t gpu_error_frames;
    uint64_t dropped_frames;
    uint64_t drawable_requests;
    uint64_t submit_samples;
    uint64_t raw_copy_samples;
    uint64_t dpcm_upload_buffer_allocations;
    uint64_t dpcm_decoded_buffer_allocations;
    uint64_t dpcm_texture_view_creations;
    uint64_t dpcm_upload_capacity_bytes;
    uint64_t dpcm_decoded_capacity_bytes;
    uint64_t inflight_frames;
    uint64_t inflight_frames_max;
    double   gpu_time_ms_total;
    double   gpu_time_ms_max;
    double   drawable_wait_ms_total;
    double   drawable_wait_ms_max;
    double   submit_time_ms_total;
    double   submit_time_ms_max;
    double   raw_copy_time_ms_total;
    double   raw_copy_time_ms_max;
    uint64_t gpu_time_histogram[TB_NATIVE_METAL_TIMING_BUCKETS];
    uint64_t drawable_wait_histogram[TB_NATIVE_METAL_TIMING_BUCKETS];
    uint64_t submit_time_histogram[TB_NATIVE_METAL_TIMING_BUCKETS];
    uint64_t raw_copy_time_histogram[TB_NATIVE_METAL_TIMING_BUCKETS];
};

/* Allocation policy used by the three DPCM upload-ring slots. Existing
 * capacity is retained; growth is geometric and never exceeds `limit`.
 * Returns zero for an invalid request. Exposed so the overflow and ceiling
 * behavior can be verified without allocating a Metal resource. */
size_t tb_native_metal_dpcm_next_upload_capacity(size_t current,
                                                  size_t required,
                                                  size_t limit);

void *tb_native_metal_create(void);
void  tb_native_metal_destroy(void *renderer);
void  tb_native_metal_set_visible(void *renderer, int visible);

/* Starts a monotonically identified presentation session with the Metal view
 * attached and drawable behind the receiver's own opaque cover. The caller
 * removes that cover only when last_presented_epoch reaches the returned token.
 * Returns zero if the native surface cannot be prepared. */
uint64_t tb_native_metal_begin_presentation_session(void *renderer);

/* Returns 1 when submitted, 0 for a temporary queue/drawable drop and -1
 * when the native renderer cannot handle the frame. */
int tb_native_metal_render_nv12(void *renderer,
                                void *pixel_buffer,
                                int cursor_x,
                                int cursor_y,
                                int cursor_source_w,
                                int cursor_source_h,
                                int cursor_visible,
                                int cursor_type,
                                int cursor_large);

/* Diagnostic path for network/software NV12. Copies the two CPU planes once
 * into a bounded pool of IOSurface-backed pixel buffers, then uses the same
 * Metal presenter as VideoToolbox frames. */
int tb_native_metal_render_nv12_planes(void *renderer,
                                       const uint8_t *y,
                                       int y_stride,
                                       const uint8_t *uv,
                                       int uv_stride,
                                       int width,
                                       int height,
                                       int cursor_x,
                                       int cursor_y,
                                       int cursor_source_w,
                                       int cursor_source_h,
                                       int cursor_visible,
                                       int cursor_type,
                                       int cursor_large);

/* Whole-frame TBD2 support is optional: it is advertised only when both the
 * audited GPU decoder and packed-BGRA presentation pipeline compiled on the
 * current Metal device. The maintained receiver intentionally accepts only
 * 8-bit TBD2 blobs for now. Returns follow the NV12 convention above, with
 * TB_NATIVE_METAL_RENDER_TRANSIENT_RETRY reserved for panel geometry/wake
 * conditions that should retry on a fresh connection. */
int tb_native_metal_supports_dpcm(void *renderer);
/* Reject decoded surfaces whose tight 32-bit BGRA footprint exceeds the
 * receiver's fixed 64 MiB allocation budget. The renderer separately checks
 * its device-aligned bytes-per-row before allocating the Metal buffer. */
int tb_native_metal_dpcm_dimensions_supported(int width, int height);
int tb_native_metal_render_dpcm(void *renderer,
                                const uint8_t *blob,
                                size_t length,
                                int cursor_x,
                                int cursor_y,
                                int cursor_source_w,
                                int cursor_source_h,
                                int cursor_visible,
                                int cursor_type,
                                int cursor_large);

int tb_native_metal_render_cursor(void *renderer,
                                  int cursor_x,
                                  int cursor_y,
                                  int cursor_source_w,
                                  int cursor_source_h,
                                  int cursor_visible,
                                  int cursor_type,
                                  int cursor_large);

void tb_native_metal_get_stats(void *renderer,
                               struct tb_native_metal_stats *stats);

/* Color diagnostics. The renderer tags its CAMetalLayer as Display P3 only
 * when the decoded CVPixelBuffer carries P3-D65 primaries; all other and
 * untagged frames use the conservative sRGB path. */
const char *tb_native_metal_pixel_buffer_color_space(void *pixel_buffer);
const char *tb_native_metal_color_space_name(void *renderer);

#if defined(TB_NATIVE_METAL_TESTING)
/* Test-only lifecycle controls. A claimed slot models a command whose
 * completion handler never fires; callers must release every successful
 * claim before destroying the test renderer. */
#define TB_NATIVE_METAL_TEST_COMPLETION_NV12 0
#define TB_NATIVE_METAL_TEST_COMPLETION_DPCM 1
int tb_native_metal_test_record_completion_failure(void *renderer,
                                                    int completion_path);
int tb_native_metal_test_has_terminal_gpu_error(void *renderer);
int tb_native_metal_test_render_admission_result(void *renderer);
int tb_native_metal_test_claim_inflight_slot(void *renderer);
int tb_native_metal_test_release_inflight_slot(void *renderer);
int tb_native_metal_test_drain_with_timeout(void *renderer,
                                            uint64_t timeout_nanoseconds);
int tb_native_metal_test_is_quarantined(void *renderer);
#endif

#ifdef __cplusplus
}
#endif

#endif
