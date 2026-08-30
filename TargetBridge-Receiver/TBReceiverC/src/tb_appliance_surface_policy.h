#ifndef TB_APPLIANCE_SURFACE_POLICY_H
#define TB_APPLIANCE_SURFACE_POLICY_H

#ifdef __cplusplus
extern "C" {
#endif

/* Pure foreground/session reducer for the dedicated receiver surface. The
 * live source is exposed, and the local cursor is suppressed, only when all
 * four public AppKit/session facts agree that this process owns the screen. */
struct tb_appliance_surface_policy {
    int privacy_blank;
    int suppress_local_cursor;
    int request_activation;
};

struct tb_appliance_surface_policy tb_appliance_surface_policy_evaluate(
    int stream_active,
    int gui_session_active,
    int app_active,
    int window_is_key);

#ifdef __cplusplus
}
#endif

#endif
