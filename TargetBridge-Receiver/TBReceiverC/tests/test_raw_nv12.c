#include "../src/raw_nv12.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;
static int checks;

#define CHECK(condition, message) do {                                      \
    checks++;                                                               \
    if (!(condition)) {                                                     \
        failures++;                                                         \
        fprintf(stderr, "FAIL %s:%d - %s\n", __FILE__, __LINE__, message); \
    }                                                                       \
} while (0)

static void put_be32(uint8_t *destination, uint32_t value) {
    destination[0] = (uint8_t)(value >> 24);
    destination[1] = (uint8_t)(value >> 16);
    destination[2] = (uint8_t)(value >> 8);
    destination[3] = (uint8_t)value;
}

static uint8_t *make_frame(uint32_t width,
                           uint32_t height,
                           uint32_t y_stride,
                           uint32_t uv_stride,
                           size_t *length) {
    const size_t y_size = (size_t)y_stride * height;
    const size_t uv_size = (size_t)uv_stride * (height / 2);
    *length = 17 + y_size + uv_size;
    uint8_t *payload = calloc(1, *length);
    if (!payload) return NULL;
    payload[0] = 1;
    put_be32(payload + 1, width);
    put_be32(payload + 5, height);
    put_be32(payload + 9, y_stride);
    put_be32(payload + 13, uv_stride);
    return payload;
}

static void test_valid_minimal(void) {
    size_t length = 0;
    uint8_t *payload = make_frame(2, 2, 4, 4, &length);
    struct tb_raw_nv12_view view;
    CHECK(payload != NULL, "minimal allocation");
    CHECK(tb_raw_nv12_parse(payload, length, &view), "minimal frame accepted");
    CHECK(view.width == 2 && view.height == 2, "minimal dimensions");
    CHECK(view.y_size == 8 && view.uv_size == 4, "minimal plane sizes");
    CHECK(view.y == payload + 17 && view.uv == payload + 25,
          "minimal plane pointers");
    free(payload);
}

static void test_valid_5k(void) {
    size_t length = 0;
    uint8_t *payload = make_frame(5120, 2880, 5120, 5120, &length);
    struct tb_raw_nv12_view view;
    CHECK(payload != NULL, "5K allocation");
    CHECK(tb_raw_nv12_parse(payload, length, &view), "5K frame accepted");
    CHECK(length == 17u + 5120u * 2880u + 5120u * 1440u,
          "5K exact payload size");
    free(payload);
}

static void test_rejects_bad_geometry(void) {
    const struct {
        uint32_t width, height, y_stride, uv_stride;
        const char *message;
    } cases[] = {
        {0, 2, 2, 2, "zero width"},
        {2, 0, 2, 2, "zero height"},
        {3, 2, 4, 4, "odd width"},
        {2, 3, 4, 4, "odd height"},
        {8194, 2, 8194, 8194, "oversized width"},
        {2, 8194, 2, 2, "oversized height"},
        {8, 2, 7, 8, "short Y stride"},
        {8, 2, 8, 7, "short UV stride"},
        {2, 2, 16385, 2, "oversized Y stride"},
        {2, 2, 2, 16385, "oversized UV stride"}
    };
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        size_t length = 0;
        uint8_t *payload = make_frame(cases[i].width, cases[i].height,
                                      cases[i].y_stride, cases[i].uv_stride,
                                      &length);
        struct tb_raw_nv12_view view;
        CHECK(payload != NULL, "bad-geometry allocation");
        CHECK(!tb_raw_nv12_parse(payload, length, &view), cases[i].message);
        free(payload);
    }
}

static void test_rejects_length_and_format_errors(void) {
    size_t length = 0;
    uint8_t *payload = make_frame(4, 4, 8, 8, &length);
    struct tb_raw_nv12_view view;
    CHECK(payload != NULL, "length-test allocation");
    for (size_t truncated = 0; truncated < length; truncated++) {
        CHECK(!tb_raw_nv12_parse(payload, truncated, &view),
              "every truncated prefix rejected");
    }
    CHECK(!tb_raw_nv12_parse(payload, length + 1, &view),
          "trailing byte rejected");
    payload[0] = 2;
    CHECK(!tb_raw_nv12_parse(payload, length, &view), "unknown format rejected");
    CHECK(!tb_raw_nv12_parse(NULL, length, &view), "null payload rejected");
    CHECK(!tb_raw_nv12_parse(payload, length, NULL), "null view rejected");
    free(payload);
}

static void test_rejects_overflow_or_hostile_headers(void) {
    uint8_t payload[17] = {1};
    struct tb_raw_nv12_view view;
    put_be32(payload + 1, UINT32_MAX - 1);
    put_be32(payload + 5, UINT32_MAX - 1);
    put_be32(payload + 9, UINT32_MAX);
    put_be32(payload + 13, UINT32_MAX);
    CHECK(!tb_raw_nv12_parse(payload, sizeof(payload), &view),
          "hostile dimensions and strides rejected");
}

int main(void) {
    test_valid_minimal();
    test_valid_5k();
    test_rejects_bad_geometry();
    test_rejects_length_and_format_errors();
    test_rejects_overflow_or_hostile_headers();
    printf("raw NV12 tests: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
