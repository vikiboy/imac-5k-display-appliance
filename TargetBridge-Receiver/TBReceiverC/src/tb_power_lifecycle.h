#ifndef TB_POWER_LIFECYCLE_H
#define TB_POWER_LIFECYCLE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Power assertions are process-scoped and macOS also removes them if the
 * receiver crashes. These IDs are kept explicitly so every normal lifecycle
 * transition releases its own assertions deterministically. */
struct tb_power_lifecycle {
    uint32_t system_sleep_assertion;
    uint32_t display_sleep_assertion;
    uint32_t user_activity_assertion;
    uint32_t logged_error_mask;
    uint8_t display_awake_held;
    uint8_t panel_wake_requested;
};

/* Hold only system idle sleep while the appliance is available. This leaves
 * the iMac panel free to follow the user's display-sleep timer between clients. */
int tb_power_lifecycle_start(struct tb_power_lifecycle *lifecycle);

/* Send one remote-user-activity wake request without taking a long-lived
 * display-sleep assertion. Repeated calls reuse the successful request until
 * the session ends. This lets a listener wake the panel before renderer setup
 * without creating assertion churn for duplicate handshakes. */
int tb_power_lifecycle_request_panel_wake(
    struct tb_power_lifecycle *lifecycle);

/* Keep an already-waking/awake panel from idling during a display session.
 * This does not itself synthesize user activity and is idempotent. */
int tb_power_lifecycle_hold_display_awake(
    struct tb_power_lifecycle *lifecycle);

/* Wake the local panel once and keep it awake for one accepted display
 * session. The display assertion, not repeated synthetic activity, owns the
 * long-lived awake state. A successful pre-session wake is reused; starting a
 * new session over an existing full session still rotates the bounded pair. */
int tb_power_lifecycle_begin_session(struct tb_power_lifecycle *lifecycle);

/* Re-enable display idle sleep without releasing the appliance-wide system
 * assertion. Safe to call when no session is active. */
void tb_power_lifecycle_end_session(struct tb_power_lifecycle *lifecycle);

/* Release session and appliance assertions. Safe to call more than once. */
void tb_power_lifecycle_stop(struct tb_power_lifecycle *lifecycle);

#ifdef __cplusplus
}
#endif

#endif
