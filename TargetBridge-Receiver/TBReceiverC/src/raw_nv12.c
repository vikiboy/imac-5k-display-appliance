#include "raw_nv12.h"

#include <limits.h>
#include <string.h>

#define TB_RAW_NV12_HEADER_SIZE 17u
#define TB_RAW_NV12_MAX_DIMENSION 8192u
#define TB_RAW_NV12_MAX_STRIDE 16384u

static uint32_t tb_raw_be32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24) |
           ((uint32_t)bytes[1] << 16) |
           ((uint32_t)bytes[2] << 8) |
           (uint32_t)bytes[3];
}

static int tb_raw_checked_multiply(size_t left, size_t right, size_t *result) {
    if (!result || (left != 0 && right > SIZE_MAX / left)) return 0;
    *result = left * right;
    return 1;
}

int tb_raw_nv12_parse(const uint8_t *payload,
                      size_t length,
                      struct tb_raw_nv12_view *view) {
    if (!payload || !view || length < TB_RAW_NV12_HEADER_SIZE) return 0;
    memset(view, 0, sizeof(*view));
    if (payload[0] != 1) return 0;

    const uint32_t width = tb_raw_be32(payload + 1);
    const uint32_t height = tb_raw_be32(payload + 5);
    const uint32_t y_stride = tb_raw_be32(payload + 9);
    const uint32_t uv_stride = tb_raw_be32(payload + 13);
    if (width == 0 || height == 0 || (width & 1u) || (height & 1u) ||
        width > TB_RAW_NV12_MAX_DIMENSION ||
        height > TB_RAW_NV12_MAX_DIMENSION ||
        y_stride < width || uv_stride < width ||
        y_stride > TB_RAW_NV12_MAX_STRIDE ||
        uv_stride > TB_RAW_NV12_MAX_STRIDE) return 0;

    size_t y_size = 0;
    size_t uv_size = 0;
    if (!tb_raw_checked_multiply((size_t)y_stride, (size_t)height, &y_size) ||
        !tb_raw_checked_multiply((size_t)uv_stride, (size_t)height / 2,
                                 &uv_size) ||
        y_size > SIZE_MAX - uv_size ||
        y_size + uv_size > SIZE_MAX - TB_RAW_NV12_HEADER_SIZE ||
        length != TB_RAW_NV12_HEADER_SIZE + y_size + uv_size) return 0;

    view->width = width;
    view->height = height;
    view->y_stride = y_stride;
    view->uv_stride = uv_stride;
    view->y_size = y_size;
    view->uv_size = uv_size;
    view->y = payload + TB_RAW_NV12_HEADER_SIZE;
    view->uv = view->y + y_size;
    return 1;
}
