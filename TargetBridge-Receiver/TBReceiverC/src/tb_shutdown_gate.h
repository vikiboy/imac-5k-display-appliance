#ifndef TB_SHUTDOWN_GATE_H
#define TB_SHUTDOWN_GATE_H

#include <pthread.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Cross-thread shutdown ownership for the dedicated receiver.
 *
 * A dispatch signal source calls tb_shutdown_gate_request() from an ordinary
 * queue context. The transport worker remains the sole close(2) owner; the
 * request path only shutdown(2)s registered sockets to wake accept/recv. The
 * mutex serializes shutdown with close so a recycled descriptor can never be
 * mistaken for the old listener or peer.
 */
struct tb_shutdown_gate {
    pthread_mutex_t mutex;
    bool initialized;
    bool requested;
    int requested_signal;
    int listener_fd;
    int peer_fd;
    int wake_read_fd;
    int wake_write_fd;
};

int tb_shutdown_gate_init(struct tb_shutdown_gate *gate);
void tb_shutdown_gate_destroy(struct tb_shutdown_gate *gate);

/* Returns 0 when admitted and ECANCELED after shutdown admission closes. */
int tb_shutdown_gate_publish_listener(struct tb_shutdown_gate *gate, int fd);
int tb_shutdown_gate_publish_peer(struct tb_shutdown_gate *gate, int fd);

/* Wait until the listener is readable or shutdown is requested. Returns 0 for
 * listener readiness, ECANCELED for shutdown, or another errno value. */
int tb_shutdown_gate_wait_for_listener(struct tb_shutdown_gate *gate, int fd);

/* The transport owner must use these instead of a bare close(2). */
void tb_shutdown_gate_close_listener(struct tb_shutdown_gate *gate, int *fd);
void tb_shutdown_gate_close_peer(struct tb_shutdown_gate *gate, int *fd);

/* Returns true only for the first request. Safe from a dispatch handler, not
 * from a POSIX async signal handler. */
bool tb_shutdown_gate_request(struct tb_shutdown_gate *gate, int signal_number);
bool tb_shutdown_gate_is_requested(struct tb_shutdown_gate *gate);
int tb_shutdown_gate_requested_signal(struct tb_shutdown_gate *gate);

#ifdef __cplusplus
}
#endif

#endif
