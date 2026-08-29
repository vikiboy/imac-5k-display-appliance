/* Validation for the diagnostic whole-frame RAW NV12 wire payload. */

#ifndef TB_RAW_NV12_H
#define TB_RAW_NV12_H

#include <stddef.h>
#include <stdint.h>

struct tb_raw_nv12_view {
    uint32_t width;
    uint32_t height;
    uint32_t y_stride;
    uint32_t uv_stride;
    size_t y_size;
    size_t uv_size;
    const uint8_t *y;
    const uint8_t *uv;
};

/* Returns 1 only for one exact, complete v1 video-range NV12 frame. */
int tb_raw_nv12_parse(const uint8_t *payload,
                      size_t length,
                      struct tb_raw_nv12_view *view);

#endif
