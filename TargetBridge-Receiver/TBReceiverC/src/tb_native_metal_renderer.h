/* Direct macOS Metal presentation for VideoToolbox NV12 pixel buffers. */

#ifndef TB_NATIVE_METAL_RENDERER_H
#define TB_NATIVE_METAL_RENDERER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Histograms retain 0.1 ms resolution through 51.2 ms. The final bucket is
 * saturating; the exact maximum alongside each histogram preserves outliers. */
#define TB_NATIVE_METAL_TIMING_BUCKETS 512
#define TB_NATIVE_METAL_TIMING_BUCKET_MS 0.1

struct tb_native_metal_stats {
    uint64_t submitted_frames;
    uint64_t completed_frames;
    uint64_t dropped_frames;
    uint64_t drawable_requests;
    uint64_t submit_samples;
    uint64_t raw_copy_samples;
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

void *tb_native_metal_create(void);
void  tb_native_metal_destroy(void *renderer);
void  tb_native_metal_set_visible(void *renderer, int visible);

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

#ifdef __cplusplus
}
#endif

#endif
