#include "tb_shutdown_gate.h"

#include <arpa/inet.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

struct blocking_call {
    int fd;
    struct tb_shutdown_gate *gate;
    atomic_bool completed;
    ssize_t result;
    int error_number;
};

static void fail(const char *message) {
    fprintf(stderr, "shutdown gate test failed: %s\n", message);
    _exit(1);
}

static bool wait_for_completion(struct blocking_call *call) {
    for (int attempt = 0; attempt < 200; attempt++) {
        if (atomic_load_explicit(&call->completed, memory_order_acquire)) {
            return true;
        }
        usleep(5000);
    }
    return atomic_load_explicit(&call->completed, memory_order_acquire);
}

static void *accept_once(void *opaque) {
    struct blocking_call *call = opaque;
    const int wait_result =
        tb_shutdown_gate_wait_for_listener(call->gate, call->fd);
    if (wait_result == 0) {
        call->result = accept(call->fd, NULL, NULL);
        call->error_number = errno;
    } else {
        call->result = -1;
        call->error_number = wait_result;
    }
    atomic_store_explicit(&call->completed, true, memory_order_release);
    return NULL;
}

static void *receive_once(void *opaque) {
    struct blocking_call *call = opaque;
    unsigned char byte = 0;
    call->result = recv(call->fd, &byte, sizeof(byte), 0);
    call->error_number = errno;
    atomic_store_explicit(&call->completed, true, memory_order_release);
    return NULL;
}

static int make_loopback_listener(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(fd, 1) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static void test_idle_listener_wakes(void) {
    struct {
        struct blocking_call call;
        struct tb_shutdown_gate gate;
    } context;
    memset(&context, 0, sizeof(context));
    atomic_init(&context.call.completed, false);
    if (tb_shutdown_gate_init(&context.gate) != 0) fail("gate init");
    int listener = make_loopback_listener();
    if (listener < 0) fail("listener setup");
    if (tb_shutdown_gate_publish_listener(&context.gate, listener) != 0) {
        fail("listener publish");
    }

    context.call.fd = listener;
    context.call.gate = &context.gate;
    pthread_t thread;
    if (pthread_create(&thread, NULL, accept_once, &context.call) != 0) {
        fail("accept thread create");
    }
    usleep(25000);
    if (!tb_shutdown_gate_request(&context.gate, SIGTERM)) fail("first request");
    if (!wait_for_completion(&context.call)) fail("accept did not wake within one second");
    if (pthread_join(thread, NULL) != 0) fail("accept thread join");
    if (context.call.result >= 0) fail("accept unexpectedly admitted a peer");
    if (context.call.error_number != ECANCELED) fail("accept wake was not cancellation");
    if (!tb_shutdown_gate_is_requested(&context.gate)) fail("request not recorded");
    if (tb_shutdown_gate_requested_signal(&context.gate) != SIGTERM) {
        fail("wrong signal recorded");
    }
    tb_shutdown_gate_close_listener(&context.gate, &listener);
    if (listener != -1) fail("listener owner close did not invalidate fd");
    tb_shutdown_gate_destroy(&context.gate);
}

static void test_active_receive_wakes(void) {
    struct tb_shutdown_gate gate;
    if (tb_shutdown_gate_init(&gate) != 0) fail("gate init");
    int peers[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, peers) != 0) {
        fail("socketpair");
    }
    if (tb_shutdown_gate_publish_peer(&gate, peers[0]) != 0) {
        fail("peer publish");
    }

    struct blocking_call call = {
        .fd = peers[0],
        .completed = ATOMIC_VAR_INIT(false),
        .result = -2,
        .error_number = 0
    };
    pthread_t thread;
    if (pthread_create(&thread, NULL, receive_once, &call) != 0) {
        fail("receive thread create");
    }
    usleep(25000);
    if (!tb_shutdown_gate_request(&gate, SIGINT)) fail("first request");
    if (!wait_for_completion(&call)) fail("recv did not wake within one second");
    if (pthread_join(thread, NULL) != 0) fail("receive thread join");
    if (call.result > 0) fail("recv unexpectedly returned payload");
    if (tb_shutdown_gate_request(&gate, SIGTERM)) {
        fail("second request reported as first");
    }
    if (tb_shutdown_gate_requested_signal(&gate) != SIGINT) {
        fail("first signal was not retained");
    }
    tb_shutdown_gate_close_peer(&gate, &peers[0]);
    close(peers[1]);
    tb_shutdown_gate_destroy(&gate);
}

static void test_closed_slot_cannot_hit_reused_descriptor(void) {
    struct tb_shutdown_gate gate;
    if (tb_shutdown_gate_init(&gate) != 0) fail("gate init");
    int original[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, original) != 0) {
        fail("original socketpair");
    }
    const int recycled_number = original[0];
    if (tb_shutdown_gate_publish_peer(&gate, original[0]) != 0) {
        fail("original publish");
    }
    tb_shutdown_gate_close_peer(&gate, &original[0]);
    close(original[1]);

    int replacement[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, replacement) != 0) {
        fail("replacement socketpair");
    }
    int replacement_fd = replacement[0];
    if (replacement_fd != recycled_number) {
        if (dup2(replacement_fd, recycled_number) != recycled_number) {
            fail("force descriptor reuse");
        }
        close(replacement_fd);
        replacement_fd = recycled_number;
    }

    if (!tb_shutdown_gate_request(&gate, SIGTERM)) fail("reuse request");
    const unsigned char sent = 0x5a;
    unsigned char received = 0;
    if (send(replacement[1], &sent, sizeof(sent), 0) != 1 ||
        recv(replacement_fd, &received, sizeof(received), 0) != 1 ||
        received != sent) {
        fail("reused descriptor was incorrectly shut down");
    }
    close(replacement_fd);
    close(replacement[1]);
    tb_shutdown_gate_destroy(&gate);
}

static void test_post_shutdown_admission_is_rejected(void) {
    struct tb_shutdown_gate gate;
    if (tb_shutdown_gate_init(&gate) != 0) fail("gate init");
    if (!tb_shutdown_gate_request(&gate, SIGTERM)) fail("request");
    int peers[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, peers) != 0) {
        fail("socketpair");
    }
    if (tb_shutdown_gate_publish_peer(&gate, peers[0]) != ECANCELED) {
        fail("post-shutdown peer was admitted");
    }
    unsigned char byte = 0;
    if (recv(peers[1], &byte, sizeof(byte), 0) != 0) {
        fail("rejected peer was not shut down");
    }
    close(peers[0]);
    close(peers[1]);
    tb_shutdown_gate_destroy(&gate);
}

int main(void) {
    test_idle_listener_wakes();
    test_active_receive_wakes();
    test_closed_slot_cannot_hit_reused_descriptor();
    test_post_shutdown_admission_is_rejected();
    puts("shutdown gate tests passed (idle listener, active peer, fd reuse, admission)");
    return 0;
}
