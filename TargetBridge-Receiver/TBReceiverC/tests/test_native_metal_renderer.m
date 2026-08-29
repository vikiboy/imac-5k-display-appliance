#import "tb_native_metal_renderer.h"

#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
    [[NSRunLoop currentRunLoop]
        runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];

    const int width = 640;
    const int height = 360;
    const int yStride = width + 32;
    const int uvStride = width + 64;
    uint8_t *y = (uint8_t *)malloc((size_t)yStride * height);
    uint8_t *uv = (uint8_t *)malloc((size_t)uvStride * (height / 2));
    int ok = y && uv;
    if (ok) {
        memset(y, 0x55, (size_t)yStride * height);
        memset(uv, 0xaa, (size_t)uvStride * (height / 2));
    }

    struct tb_native_metal_stats baseline;
    tb_native_metal_get_stats(renderer, &baseline);
    int firstResult = -1;
    if (ok) {
        firstResult = tb_native_metal_render_nv12_planes(
            renderer, y, yStride, uv, uvStride, width, height,
            10, 20, width, height, 1, 0, 0);
        /* The renderer must already own its staging copy when this returns. */
        memset(y, 0xee, (size_t)yStride * height);
        memset(uv, 0x11, (size_t)uvStride * (height / 2));
        ok = firstResult == 1 &&
             wait_for_completions(renderer, baseline.completed_frames + 1);
    }

    struct tb_native_metal_stats afterFirst;
    tb_native_metal_get_stats(renderer, &afterFirst);
    if (ok) {
        ok = afterFirst.raw_copy_samples == baseline.raw_copy_samples + 1 &&
             afterFirst.submitted_frames == baseline.submitted_frames + 1;
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
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            printf("native Metal renderer test: skipped (no Metal device)\n");
            return 0;
        }

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
        printf("native Metal renderer test: device=%s shader/pipeline passed\n",
               device.name.UTF8String ?: "unknown");
        return 0;
    }
}
