#import "tb_native_metal_renderer.h"

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

#include <arpa/inet.h>
#include <errno.h>
#include <inttypes.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static void fail(const char *operation) {
    fprintf(stderr, "TB_NETWORK_METAL error=%s errno=%d message=%s\n",
            operation, errno, strerror(errno));
    exit(1);
}

static uint32_t load_be32(const uint8_t *source) {
    return ((uint32_t)source[0] << 24) |
           ((uint32_t)source[1] << 16) |
           ((uint32_t)source[2] << 8) |
           (uint32_t)source[3];
}

static uint64_t host_to_network_u64(uint64_t value) {
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    return ((uint64_t)htonl((uint32_t)(value >> 32))) |
           ((uint64_t)htonl((uint32_t)value) << 32);
#else
    return value;
#endif
}

static bool read_exact(int fd, void *buffer, size_t length) {
    uint8_t *cursor = (uint8_t *)buffer;
    while (length > 0) {
        ssize_t received = recv(fd, cursor, length, 0);
        if (received < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (received == 0) return false;
        cursor += (size_t)received;
        length -= (size_t)received;
    }
    return true;
}

static bool write_exact(int fd, const void *buffer, size_t length) {
    const uint8_t *cursor = (const uint8_t *)buffer;
    while (length > 0) {
        ssize_t written = send(fd, cursor, length, 0);
        if (written < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (written == 0) return false;
        cursor += (size_t)written;
        length -= (size_t)written;
    }
    return true;
}

static int compare_double(const void *left, const void *right) {
    double a = *(const double *)left;
    double b = *(const double *)right;
    return (a > b) - (a < b);
}

static double percentile(double *values, uint32_t count, unsigned wanted) {
    if (count == 0) return 0.0;
    qsort(values, count, sizeof(*values), compare_double);
    uint64_t rank = ((uint64_t)count * wanted + 99) / 100;
    if (rank == 0) rank = 1;
    if (rank > count) rank = count;
    return values[rank - 1];
}

static double renderer_histogram_percentile(
    const uint64_t histogram[TB_NATIVE_METAL_TIMING_BUCKETS],
    unsigned wanted) {
    uint64_t count = 0;
    for (size_t index = 0; index < TB_NATIVE_METAL_TIMING_BUCKETS; index++) {
        count += histogram[index];
    }
    if (count == 0) return 0.0;
    uint64_t rank = (count * wanted + 99) / 100;
    uint64_t cumulative = 0;
    for (size_t index = 0; index < TB_NATIVE_METAL_TIMING_BUCKETS; index++) {
        cumulative += histogram[index];
        if (cumulative >= rank) {
            return (double)(index + 1) * TB_NATIVE_METAL_TIMING_BUCKET_MS;
        }
    }
    return TB_NATIVE_METAL_TIMING_BUCKETS * TB_NATIVE_METAL_TIMING_BUCKET_MS;
}

static int make_listener(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) fail("socket");
    int reuse = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    int requested = 4 * 1024 * 1024;
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &requested, sizeof(requested));
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) fail("bind");
    if (listen(fd, 1) != 0) fail("listen");
    return fd;
}

static bool receive_frame(int fd,
                          uint8_t *frame,
                          size_t length,
                          double *active_milliseconds,
                          double *completed_at) {
    size_t first_request = length < 65536 ? length : 65536;
    ssize_t first = 0;
    do {
        first = recv(fd, frame, first_request, 0);
    } while (first < 0 && errno == EINTR);
    if (first <= 0) return false;
    double first_received = CACurrentMediaTime();

    size_t total = (size_t)first;
    if (total < length && !read_exact(fd, frame + total, length - total)) return false;
    *completed_at = CACurrentMediaTime();
    *active_milliseconds = (*completed_at - first_received) * 1000.0;
    return true;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 6) {
            fprintf(stderr,
                    "usage: %s <width> <height> <frames>=120 <fps> <port>\n",
                    argv[0]);
            return 64;
        }
        const int width = atoi(argv[1]);
        const int height = atoi(argv[2]);
        const int expectedFrames = atoi(argv[3]);
        const int targetFPS = atoi(argv[4]);
        const int portValue = atoi(argv[5]);
        if (width <= 0 || height <= 0 || (width & 1) || (height & 1) ||
            width > 8192 || height > 8192 || expectedFrames < 120 ||
            targetFPS <= 0 || targetFPS > 240 || portValue <= 0 ||
            portValue > 65535) {
            fprintf(stderr, "TB_NETWORK_METAL result=failed reason=arguments\n");
            return 64;
        }
        uint64_t yBytes = (uint64_t)width * (uint64_t)height;
        uint64_t frameBytes64 = yBytes + yBytes / 2;
        if (frameBytes64 > SIZE_MAX || frameBytes64 > UINT32_MAX) {
            fprintf(stderr, "TB_NETWORK_METAL result=failed reason=frame-overflow\n");
            return 64;
        }
        const size_t frameBytes = (size_t)frameBytes64;

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSScreen *screen = NSScreen.mainScreen;
        if (!screen || !MTLCreateSystemDefaultDevice()) {
            fprintf(stderr, "TB_NETWORK_METAL result=failed reason=no-display-device\n");
            return 69;
        }
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:screen.frame
                      styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered
                          defer:NO
                         screen:screen];
        window.title = @"TargetBridge Network Metal Receiver";
        window.releasedWhenClosed = NO;
        window.backgroundColor = NSColor.blackColor;
        window.opaque = YES;
        [window orderFrontRegardless];
        [[NSRunLoop currentRunLoop]
            runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];

        void *renderer = tb_native_metal_create();
        uint8_t *frame = (uint8_t *)malloc(frameBytes);
        double *activeTimes = (double *)calloc(
            (size_t)expectedFrames, sizeof(*activeTimes));
        double *completionGaps = (double *)calloc(
            (size_t)expectedFrames, sizeof(*completionGaps));
        if (!renderer || !frame || !activeTimes || !completionGaps) {
            fprintf(stderr, "TB_NETWORK_METAL result=failed reason=allocation\n");
            free(completionGaps);
            free(activeTimes);
            free(frame);
            if (renderer) tb_native_metal_destroy(renderer);
            [window close];
            return 70;
        }
        tb_native_metal_set_visible(renderer, 1);

        signal(SIGPIPE, SIG_IGN);
        int listener = make_listener((uint16_t)portValue);
        printf("TB_NETWORK_METAL state=listening port=%d expected=%dx%d@%d frames=%d\n",
               portValue, width, height, targetFPS, expectedFrames);
        fflush(stdout);
        int peer = accept(listener, NULL, NULL);
        if (peer < 0) fail("accept");
        int requested = 4 * 1024 * 1024;
        (void)setsockopt(peer, SOL_SOCKET, SO_RCVBUF, &requested, sizeof(requested));

        uint8_t header[24];
        static const uint8_t expectedMagic[8] = {
            'T', 'B', 'N', 'V', '1', '2', 'V', '1'
        };
        if (!read_exact(peer, header, sizeof(header)) ||
            memcmp(header, expectedMagic, sizeof(expectedMagic)) != 0 ||
            load_be32(header + 8) != (uint32_t)width ||
            load_be32(header + 12) != (uint32_t)height ||
            load_be32(header + 16) != (uint32_t)expectedFrames ||
            load_be32(header + 20) != (uint32_t)frameBytes) {
            fprintf(stderr, "TB_NETWORK_METAL result=failed reason=handshake\n");
            close(peer);
            close(listener);
            free(completionGaps);
            free(activeTimes);
            free(frame);
            tb_native_metal_destroy(renderer);
            [window close];
            return 72;
        }

        uint32_t receivedFrames = 0;
        double activeTotal = 0.0;
        double activeMax = 0.0;
        double previousCompletion = 0.0;
        double firstCompletion = 0.0;
        double lastCompletion = 0.0;
        for (int index = 0; index < expectedFrames; index++) {
            double active = 0.0;
            double completed = 0.0;
            if (!receive_frame(peer, frame, frameBytes, &active, &completed)) break;
            if (receivedFrames == 0) firstCompletion = completed;
            if (previousCompletion > 0.0) {
                completionGaps[receivedFrames - 1] =
                    (completed - previousCompletion) * 1000.0;
            }
            previousCompletion = completed;
            lastCompletion = completed;
            activeTimes[receivedFrames] = active;
            activeTotal += active;
            if (active > activeMax) activeMax = active;
            receivedFrames++;

            (void)tb_native_metal_render_nv12_planes(
                renderer,
                frame, width,
                frame + yBytes, width,
                width, height,
                (index * 13) % width, (index * 7) % height,
                width, height, 0, 0, 0);
        }

        struct tb_native_metal_stats stats;
        const CFTimeInterval deadline = CACurrentMediaTime() + 3.0;
        do {
            tb_native_metal_get_stats(renderer, &stats);
            if (stats.completed_frames >= stats.submitted_frames) break;
            [[NSRunLoop currentRunLoop]
                runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
        } while (CACurrentMediaTime() < deadline);
        tb_native_metal_get_stats(renderer, &stats);

        uint64_t acknowledgement = host_to_network_u64(receivedFrames);
        bool acknowledged = write_exact(peer, &acknowledgement, sizeof(acknowledgement));
        shutdown(peer, SHUT_WR);

        uint32_t gapCount = receivedFrames > 1 ? receivedFrames - 1 : 0;
        double elapsed = receivedFrames > 1 ? lastCompletion - firstCompletion : 0.0;
        double actualFPS = elapsed > 0.0 ? (double)(receivedFrames - 1) / elapsed : 0.0;
        bool ok = acknowledged && receivedFrames == (uint32_t)expectedFrames &&
                  stats.gpu_error_frames == 0 &&
                  stats.dropped_frames == 0 &&
                  stats.completed_frames == stats.submitted_frames;
        printf(
            "TB_NETWORK_METAL result=%s size=%dx%d targetFPS=%d received=%u "
            "actualFPS=%.3f payloadGbps=%.3f submitted=%llu completed=%llu "
            "dropped=%llu inflightMax=%llu receiveActiveAvg=%.3fms "
            "receiveActiveP50=%.3fms receiveActiveP95=%.3fms "
            "receiveActiveP99=%.3fms receiveActiveMax=%.3fms "
            "completionGapP50=%.3fms completionGapP95=%.3fms "
            "completionGapP99=%.3fms rawCopyP99=%.2fms "
            "submitP99=%.2fms gpuP99=%.2fms color=%s\n",
            ok ? "ok" : "failed",
            width, height, targetFPS, receivedFrames, actualFPS,
            actualFPS * (double)frameBytes * 8.0 / 1000000000.0,
            (unsigned long long)stats.submitted_frames,
            (unsigned long long)stats.completed_frames,
            (unsigned long long)stats.dropped_frames,
            (unsigned long long)stats.inflight_frames_max,
            receivedFrames ? activeTotal / receivedFrames : 0.0,
            percentile(activeTimes, receivedFrames, 50),
            percentile(activeTimes, receivedFrames, 95),
            percentile(activeTimes, receivedFrames, 99),
            activeMax,
            percentile(completionGaps, gapCount, 50),
            percentile(completionGaps, gapCount, 95),
            percentile(completionGaps, gapCount, 99),
            renderer_histogram_percentile(stats.raw_copy_time_histogram, 99),
            renderer_histogram_percentile(stats.submit_time_histogram, 99),
            renderer_histogram_percentile(stats.gpu_time_histogram, 99),
            tb_native_metal_color_space_name(renderer));
        fflush(stdout);

        close(peer);
        close(listener);
        free(completionGaps);
        free(activeTimes);
        free(frame);
        tb_native_metal_destroy(renderer);
        [window close];
        return ok ? 0 : 2;
    }
}
