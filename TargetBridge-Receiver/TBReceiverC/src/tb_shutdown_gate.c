#include "tb_shutdown_gate.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int tb_shutdown_gate_publish(struct tb_shutdown_gate *gate,
                                    int *slot,
                                    int fd) {
    if (!gate || !gate->initialized || !slot || fd < 0) return EINVAL;
    int result = 0;
    pthread_mutex_lock(&gate->mutex);
    if (gate->requested) {
        (void)shutdown(fd, SHUT_RDWR);
        result = ECANCELED;
    } else if (*slot >= 0) {
        result = EBUSY;
    } else {
        *slot = fd;
    }
    pthread_mutex_unlock(&gate->mutex);
    return result;
}

static void tb_shutdown_gate_close(struct tb_shutdown_gate *gate,
                                   int *slot,
                                   int *fd) {
    if (!fd || *fd < 0) return;
    const int descriptor = *fd;
    if (!gate || !gate->initialized || !slot) {
        *fd = -1;
        (void)close(descriptor);
        return;
    }

    pthread_mutex_lock(&gate->mutex);
    if (*slot == descriptor) *slot = -1;
    *fd = -1;
    /* Keep the mutex through close. A concurrent shutdown request therefore
     * cannot act on this numeric descriptor after the kernel recycles it. */
    (void)close(descriptor);
    pthread_mutex_unlock(&gate->mutex);
}

int tb_shutdown_gate_init(struct tb_shutdown_gate *gate) {
    if (!gate) return EINVAL;
    memset(gate, 0, sizeof(*gate));
    gate->listener_fd = -1;
    gate->peer_fd = -1;
    gate->wake_read_fd = -1;
    gate->wake_write_fd = -1;
    const int result = pthread_mutex_init(&gate->mutex, NULL);
    if (result != 0) return result;
    int wake_pipe[2];
    if (pipe(wake_pipe) != 0) {
        const int pipe_error = errno;
        (void)pthread_mutex_destroy(&gate->mutex);
        return pipe_error;
    }
    gate->wake_read_fd = wake_pipe[0];
    gate->wake_write_fd = wake_pipe[1];
    for (size_t index = 0; index < 2; index++) {
        const int descriptor = wake_pipe[index];
        const int status_flags = fcntl(descriptor, F_GETFL, 0);
        if (status_flags >= 0) {
            (void)fcntl(descriptor, F_SETFL, status_flags | O_NONBLOCK);
        }
        const int descriptor_flags = fcntl(descriptor, F_GETFD, 0);
        if (descriptor_flags >= 0) {
            (void)fcntl(descriptor, F_SETFD, descriptor_flags | FD_CLOEXEC);
        }
    }
    gate->initialized = true;
    return 0;
}

void tb_shutdown_gate_destroy(struct tb_shutdown_gate *gate) {
    if (!gate || !gate->initialized) return;
    pthread_mutex_lock(&gate->mutex);
    gate->listener_fd = -1;
    gate->peer_fd = -1;
    const int wake_read_fd = gate->wake_read_fd;
    const int wake_write_fd = gate->wake_write_fd;
    gate->wake_read_fd = -1;
    gate->wake_write_fd = -1;
    gate->initialized = false;
    if (wake_read_fd >= 0) (void)close(wake_read_fd);
    if (wake_write_fd >= 0) (void)close(wake_write_fd);
    pthread_mutex_unlock(&gate->mutex);
    (void)pthread_mutex_destroy(&gate->mutex);
}

int tb_shutdown_gate_publish_listener(struct tb_shutdown_gate *gate, int fd) {
    if (!gate) return EINVAL;
    return tb_shutdown_gate_publish(gate, &gate->listener_fd, fd);
}

int tb_shutdown_gate_publish_peer(struct tb_shutdown_gate *gate, int fd) {
    if (!gate) return EINVAL;
    return tb_shutdown_gate_publish(gate, &gate->peer_fd, fd);
}

int tb_shutdown_gate_wait_for_listener(struct tb_shutdown_gate *gate, int fd) {
    if (!gate || !gate->initialized || fd < 0) return EINVAL;
    for (;;) {
        pthread_mutex_lock(&gate->mutex);
        const bool requested = gate->requested;
        const int wake_read_fd = gate->wake_read_fd;
        pthread_mutex_unlock(&gate->mutex);
        if (requested) return ECANCELED;
        if (wake_read_fd < 0) return EBADF;

        struct pollfd descriptors[2] = {
            { .fd = fd, .events = POLLIN, .revents = 0 },
            { .fd = wake_read_fd, .events = POLLIN, .revents = 0 }
        };
        int ready;
        do {
            ready = poll(descriptors, 2, -1);
        } while (ready < 0 && errno == EINTR);
        if (ready < 0) return errno;

        if (descriptors[1].revents != 0) {
            unsigned char scratch[32];
            while (read(wake_read_fd, scratch, sizeof(scratch)) > 0) {}
            if (tb_shutdown_gate_is_requested(gate)) return ECANCELED;
        }
        if (descriptors[0].revents != 0) return 0;
    }
}

void tb_shutdown_gate_close_listener(struct tb_shutdown_gate *gate, int *fd) {
    tb_shutdown_gate_close(gate, gate ? &gate->listener_fd : NULL, fd);
}

void tb_shutdown_gate_close_peer(struct tb_shutdown_gate *gate, int *fd) {
    tb_shutdown_gate_close(gate, gate ? &gate->peer_fd : NULL, fd);
}

bool tb_shutdown_gate_request(struct tb_shutdown_gate *gate,
                              int signal_number) {
    if (!gate || !gate->initialized) return false;
    pthread_mutex_lock(&gate->mutex);
    const bool first_request = !gate->requested;
    if (first_request) {
        gate->requested = true;
        gate->requested_signal = signal_number;
    }
    if (gate->peer_fd >= 0) {
        (void)shutdown(gate->peer_fd, SHUT_RDWR);
    }
    if (gate->listener_fd >= 0) {
        (void)shutdown(gate->listener_fd, SHUT_RDWR);
    }
    if (gate->wake_write_fd >= 0) {
        const unsigned char wake_byte = 1;
        (void)write(gate->wake_write_fd, &wake_byte, sizeof(wake_byte));
    }
    pthread_mutex_unlock(&gate->mutex);
    return first_request;
}

bool tb_shutdown_gate_is_requested(struct tb_shutdown_gate *gate) {
    if (!gate || !gate->initialized) return false;
    pthread_mutex_lock(&gate->mutex);
    const bool requested = gate->requested;
    pthread_mutex_unlock(&gate->mutex);
    return requested;
}

int tb_shutdown_gate_requested_signal(struct tb_shutdown_gate *gate) {
    if (!gate || !gate->initialized) return 0;
    pthread_mutex_lock(&gate->mutex);
    const int signal_number = gate->requested_signal;
    pthread_mutex_unlock(&gate->mutex);
    return signal_number;
}
