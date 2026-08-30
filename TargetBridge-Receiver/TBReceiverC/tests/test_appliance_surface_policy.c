#include "tb_appliance_surface_policy.h"

#include <stdio.h>
#include <stdlib.h>

static void require_policy(int stream,
                           int gui,
                           int app,
                           int key,
                           int blank,
                           int cursor,
                           int activate,
                           const char *label) {
    const struct tb_appliance_surface_policy policy =
        tb_appliance_surface_policy_evaluate(stream, gui, app, key);
    if (policy.privacy_blank != blank ||
        policy.suppress_local_cursor != cursor ||
        policy.request_activation != activate) {
        fprintf(stderr,
                "appliance surface policy failed: %s "
                "got blank=%d cursor=%d activate=%d\n",
                label,
                policy.privacy_blank,
                policy.suppress_local_cursor,
                policy.request_activation);
        exit(1);
    }
}

int main(void) {
    require_policy(0, 0, 0, 0, 1, 0, 0, "locked idle");
    require_policy(1, 0, 0, 0, 1, 0, 0, "locked stream");
    require_policy(1, 1, 0, 0, 1, 0, 1, "unlocked inactive stream");
    require_policy(1, 1, 1, 0, 1, 0, 1, "active non-key stream");
    require_policy(1, 1, 1, 1, 0, 1, 0, "owned live stream");
    require_policy(0, 1, 1, 0, 0, 0, 0, "owned idle surface");
    require_policy(0, 1, 0, 0, 1, 0, 1, "inactive idle surface");

    /* A same-app panel can become key without the whole app resigning active.
     * Exercise that exact key -> non-key -> key transition: the receiver must
     * cover pixels and release the local cursor while it is non-key, then
     * restore both invariants when it owns the display surface again. */
    require_policy(1, 1, 1, 1, 0, 1, 0, "key lifecycle: owned");
    require_policy(1, 1, 1, 0, 1, 0, 1, "key lifecycle: resigned");
    require_policy(1, 1, 1, 1, 0, 1, 0, "key lifecycle: reclaimed");
    printf("appliance surface policy passed (secure blank/cursor ownership truth table)\n");
    return 0;
}
