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
    const int owns_live_surface = stream && gui && app && key;
    struct tb_appliance_surface_policy policy;
    policy.privacy_blank = !gui || !app || (stream && !key);
    policy.suppress_local_cursor = owns_live_surface;
    policy.request_activation = gui && (!app || (stream && !key));
    return policy;
}
