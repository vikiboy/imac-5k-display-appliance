#include "tb_appliance_surface_policy.h"

struct tb_appliance_surface_policy tb_appliance_surface_policy_evaluate(
    int stream_active,
    int gui_session_active,
    int app_active,
    int window_is_key) {
    const int stream = stream_active != 0;
    const int gui = gui_session_active != 0;
    const int app = app_active != 0;
    const int key = window_is_key != 0;
    /* App focus and key-window ownership are presentation conveniences, not
     * security boundaries. Screen Sharing, a system panel, or another local
     * window can transiently take either while the unlocked Aqua session still
     * owns the built-in panel. Treating that as a secure-session loss produces
     * a black flash and releases the iMac's cursor over an otherwise live
     * monitor image. The GUI-session gate remains fail-closed across lock,
     * logout and fast-user switching; focus is reclaimed independently. */
    const int owns_live_surface = stream && gui;
    struct tb_appliance_surface_policy policy;
    policy.privacy_blank = !gui;
    policy.suppress_local_cursor = owns_live_surface;
    policy.request_activation = gui && (!app || (stream && !key));
    return policy;
}
