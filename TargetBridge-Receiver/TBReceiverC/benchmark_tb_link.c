#include <arpa/inet.h>
#include <errno.h>
#include <inttypes.h>
#include <netinet/in.h>
#if defined(__APPLE__)
#include <pthread/qos.h>
#endif
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

enum { kChunkBytes = 1024 * 1024 };

static void die(const char *operation) {
    fprintf(stderr, "TB_LINK_BENCH error=%s errno=%d message=%s\n",
            operation, errno, strerror(errno));
    exit(1);
}

static double monotonic_seconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) {
        die("clock_gettime");
    }
    return (double)value.tv_sec + (double)value.tv_nsec / 1000000000.0;
}

static uint64_t parse_u64(const char *text, const char *label) {
    char *end = NULL;
    errno = 0;
    unsigned long long value = strtoull(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value == 0) {
        fprintf(stderr, "TB_LINK_BENCH error=invalid_%s value=%s\n", label, text);
        exit(2);
    }
    return (uint64_t)value;
}

static uint16_t parse_port(const char *text) {
    uint64_t value = parse_u64(text, "port");
    if (value > 65535) {
        fprintf(stderr, "TB_LINK_BENCH error=invalid_port value=%s\n", text);
        exit(2);
    }
    return (uint16_t)value;
}

static uint64_t host_to_network_u64(uint64_t value) {
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    return ((uint64_t)htonl((uint32_t)(value >> 32))) |
           ((uint64_t)htonl((uint32_t)value) << 32);
#else
    return value;
#endif
}

static uint64_t network_to_host_u64(uint64_t value) {
    return host_to_network_u64(value);
}

static void store_be32(uint8_t *destination, uint32_t value) {
    destination[0] = (uint8_t)(value >> 24);
    destination[1] = (uint8_t)(value >> 16);
    destination[2] = (uint8_t)(value >> 8);
    destination[3] = (uint8_t)value;
}

static void tune_socket(int fd) {
    int requested = 4 * 1024 * 1024;
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &requested, sizeof(requested));
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &requested, sizeof(requested));
}

static void write_all(int fd, const void *buffer, size_t length) {
    const uint8_t *cursor = buffer;
    while (length > 0) {
        ssize_t written = send(fd, cursor, length, 0);
        if (written < 0) {
            if (errno == EINTR) continue;
            die("send");
        }
        if (written == 0) die("send_zero");
        cursor += (size_t)written;
        length -= (size_t)written;
    }
}

static void read_all(int fd, void *buffer, size_t length) {
    uint8_t *cursor = buffer;
    while (length > 0) {
        ssize_t received = recv(fd, cursor, length, 0);
        if (received < 0) {
            if (errno == EINTR) continue;
            die("recv");
        }
        if (received == 0) {
            fprintf(stderr, "TB_LINK_BENCH error=unexpected_eof remaining=%zu\n", length);
            exit(1);
        }
        cursor += (size_t)received;
        length -= (size_t)received;
    }
}

static void print_result(const char *role, uint64_t bytes, double elapsed) {
    double gbps = ((double)bytes * 8.0) / elapsed / 1000000000.0;
    double mibps = ((double)bytes / (1024.0 * 1024.0)) / elapsed;
    printf("TB_LINK_BENCH result=ok role=%s bytes=%" PRIu64
           " elapsed=%.6fs gbps=%.3f MiBps=%.1f\n",
           role, bytes, elapsed, gbps, mibps);
    fflush(stdout);
}

static struct sockaddr_in make_address(const char *address, uint16_t port) {
    struct sockaddr_in result;
    memset(&result, 0, sizeof(result));
    result.sin_family = AF_INET;
    result.sin_port = htons(port);
    if (inet_pton(AF_INET, address, &result.sin_addr) != 1) {
        fprintf(stderr, "TB_LINK_BENCH error=invalid_ipv4 value=%s\n", address);
        exit(2);
    }
    return result;
}

static int run_receive(const char *bind_address, uint16_t port, uint64_t expected) {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) die("socket");
    int reuse = 1;
    (void)setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    tune_socket(listener);

    struct sockaddr_in address = make_address(bind_address, port);
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0) die("bind");
    if (listen(listener, 1) != 0) die("listen");
    printf("TB_LINK_BENCH state=listening address=%s port=%u expected=%" PRIu64 "\n",
           bind_address, (unsigned)port, expected);
    fflush(stdout);

    int peer = accept(listener, NULL, NULL);
    if (peer < 0) die("accept");
    tune_socket(peer);

    uint8_t *buffer = malloc(kChunkBytes);
    if (buffer == NULL) die("malloc");
    uint64_t total = 0;
    double start = monotonic_seconds();
    while (total < expected) {
        size_t remaining = (size_t)((expected - total) < kChunkBytes
                                        ? (expected - total)
                                        : kChunkBytes);
        ssize_t received = recv(peer, buffer, remaining, 0);
        if (received < 0) {
            if (errno == EINTR) continue;
            die("recv_payload");
        }
        if (received == 0) break;
        total += (uint64_t)received;
    }
    double elapsed = monotonic_seconds() - start;

    uint64_t acknowledgement = host_to_network_u64(total);
    write_all(peer, &acknowledgement, sizeof(acknowledgement));
    shutdown(peer, SHUT_WR);
    print_result("receive", total, elapsed);

    free(buffer);
    close(peer);
    close(listener);
    return total == expected ? 0 : 1;
}

static int run_send(const char *remote_address, uint16_t port, uint64_t expected) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) die("socket");
    tune_socket(fd);
    struct sockaddr_in address = make_address(remote_address, port);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) die("connect");

    uint8_t *buffer = malloc(kChunkBytes);
    if (buffer == NULL) die("malloc");
    memset(buffer, 0xa5, kChunkBytes);

    uint64_t total = 0;
    double start = monotonic_seconds();
    while (total < expected) {
        size_t remaining = (size_t)((expected - total) < kChunkBytes
                                        ? (expected - total)
                                        : kChunkBytes);
        write_all(fd, buffer, remaining);
        total += remaining;
    }
    shutdown(fd, SHUT_WR);

    uint64_t acknowledgement = 0;
    read_all(fd, &acknowledgement, sizeof(acknowledgement));
    double elapsed = monotonic_seconds() - start;
    acknowledgement = network_to_host_u64(acknowledgement);
    print_result("send", acknowledgement, elapsed);

    free(buffer);
    close(fd);
    return acknowledgement == expected ? 0 : 1;
}

static void sleep_until(double target) {
    for (;;) {
        double remaining = target - monotonic_seconds();
        if (remaining <= 0.0) return;
        struct timespec delay = {
            .tv_sec = (time_t)remaining,
            .tv_nsec = (long)((remaining - (double)(time_t)remaining) * 1000000000.0)
        };
        if (nanosleep(&delay, NULL) == 0) return;
        if (errno != EINTR) die("nanosleep");
    }
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

static int run_send_frames(const char *remote_address,
                           uint16_t port,
                           uint32_t width,
                           uint32_t height,
                           uint32_t frames,
                           uint32_t fps) {
#if defined(__APPLE__)
    (void)pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif
    if (width == 0 || height == 0 || (width & 1u) || (height & 1u) ||
        width > 8192 || height > 8192 || frames < 120 || fps == 0 || fps > 240) {
        fprintf(stderr, "TB_LINK_BENCH error=invalid_frame_session\n");
        return 2;
    }
    uint64_t y_bytes = (uint64_t)width * height;
    uint64_t frame_bytes_u64 = y_bytes + y_bytes / 2;
    if (frame_bytes_u64 > UINT32_MAX ||
        frame_bytes_u64 > SIZE_MAX || frames > UINT64_MAX / frame_bytes_u64) {
        fprintf(stderr, "TB_LINK_BENCH error=frame_session_overflow\n");
        return 2;
    }
    uint32_t frame_bytes = (uint32_t)frame_bytes_u64;

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) die("socket");
    tune_socket(fd);
    struct sockaddr_in address = make_address(remote_address, port);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) die("connect");

    uint8_t header[24] = { 'T', 'B', 'N', 'V', '1', '2', 'V', '1' };
    store_be32(header + 8, width);
    store_be32(header + 12, height);
    store_be32(header + 16, frames);
    store_be32(header + 20, frame_bytes);
    write_all(fd, header, sizeof(header));

    uint8_t *frame = malloc(frame_bytes);
    double *send_times = calloc(frames, sizeof(*send_times));
    if (frame == NULL || send_times == NULL) die("malloc_frames");
    memset(frame + y_bytes, 128, (size_t)(frame_bytes_u64 - y_bytes));

    double start = monotonic_seconds();
    double send_max = 0.0;
    double send_total = 0.0;
    for (uint32_t index = 0; index < frames; index++) {
        sleep_until(start + (double)index / (double)fps);
        memset(frame, 16 + (index % 200), (size_t)y_bytes);
        double send_start = monotonic_seconds();
        write_all(fd, frame, frame_bytes);
        double send_ms = (monotonic_seconds() - send_start) * 1000.0;
        send_times[index] = send_ms;
        send_total += send_ms;
        if (send_ms > send_max) send_max = send_ms;
    }
    shutdown(fd, SHUT_WR);

    uint64_t acknowledgement = 0;
    read_all(fd, &acknowledgement, sizeof(acknowledgement));
    double elapsed = monotonic_seconds() - start;
    acknowledgement = network_to_host_u64(acknowledgement);
    uint64_t total_bytes = (uint64_t)frames * frame_bytes;
    printf("TB_FRAME_BENCH result=%s role=send size=%ux%u frames=%u "
           "acknowledged=%" PRIu64 " targetFPS=%u elapsed=%.6fs actualFPS=%.3f "
           "payloadGbps=%.3f sendAvg=%.3fms sendP50=%.3fms sendP95=%.3fms "
           "sendP99=%.3fms sendMax=%.3fms\n",
           acknowledgement == frames ? "ok" : "mismatch",
           width, height, frames, acknowledgement, fps, elapsed,
           (double)frames / elapsed,
           (double)total_bytes * 8.0 / elapsed / 1000000000.0,
           send_total / frames,
           percentile(send_times, frames, 50),
           percentile(send_times, frames, 95),
           percentile(send_times, frames, 99),
           send_max);

    free(send_times);
    free(frame);
    close(fd);
    return acknowledgement == frames ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc == 8 && strcmp(argv[1], "send-frames") == 0) {
        uint16_t port = parse_port(argv[3]);
        uint64_t width = parse_u64(argv[4], "width");
        uint64_t height = parse_u64(argv[5], "height");
        uint64_t frames = parse_u64(argv[6], "frames");
        uint64_t fps = parse_u64(argv[7], "fps");
        if (width > UINT32_MAX || height > UINT32_MAX ||
            frames > UINT32_MAX || fps > UINT32_MAX) {
            fprintf(stderr, "TB_LINK_BENCH error=frame_argument_overflow\n");
            return 2;
        }
        signal(SIGPIPE, SIG_IGN);
        return run_send_frames(argv[2], port, (uint32_t)width,
                               (uint32_t)height, (uint32_t)frames,
                               (uint32_t)fps);
    }
    if (argc != 5 ||
        (strcmp(argv[1], "receive") != 0 && strcmp(argv[1], "send") != 0)) {
        fprintf(stderr,
                "usage: %s receive <bind-ipv4> <port> <bytes>\n"
                "       %s send <remote-ipv4> <port> <bytes>\n"
                "       %s send-frames <remote-ipv4> <port> "
                "<width> <height> <frames> <fps>\n",
                argv[0], argv[0], argv[0]);
        return 2;
    }
    signal(SIGPIPE, SIG_IGN);
    uint16_t port = parse_port(argv[3]);
    uint64_t bytes = parse_u64(argv[4], "bytes");
    return strcmp(argv[1], "receive") == 0
               ? run_receive(argv[2], port, bytes)
               : run_send(argv[2], port, bytes);
}
