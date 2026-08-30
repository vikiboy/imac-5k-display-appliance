#include "tb_display_lifecycle.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void require(int condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "display lifecycle failed: %s\n", message);
        exit(1);
    }
}

int main(void) {
    struct tb_display_lifecycle state;
    tb_display_lifecycle_init(&state, 0);

    /* Launch in an inactive/unknown Aqua session is fail-closed. */
    require(!tb_display_lifecycle_accepts_frames(&state),
            "inactive launch must reject frames");
    require(!tb_display_lifecycle_wants_display_power(&state),
            "inactive launch must not hold display power");
    require(!tb_display_lifecycle_may_expose_pixels(&state),
            "inactive launch must stay black");
    require(!tb_display_lifecycle_may_hide_cursor(&state),
            "inactive launch must leave cursor released");

    require(tb_display_lifecycle_set_receiver_surface(&state, 1) ==
                TB_DISPLAY_LIFECYCLE_APPLIED,
            "surface activation applies once");
    require(tb_display_lifecycle_set_receiver_surface(&state, 1) ==
                TB_DISPLAY_LIFECYCLE_DUPLICATE,
            "surface activation is idempotent");
    require(tb_display_lifecycle_wants_display_power(&state),
            "awake source and active surface request power");
    require(!tb_display_lifecycle_accepts_frames(&state),
            "surface waits for sender's ordered epoch acknowledgement");
    require(tb_display_lifecycle_ack_receiver_epoch(
                &state, state.receiver_epoch) ==
                TB_DISPLAY_LIFECYCLE_APPLIED,
            "current receiver epoch acknowledgement applies");
    require(!tb_display_lifecycle_may_expose_pixels(&state),
            "power alone never exposes a stale frame");

    const uint64_t first_generation = state.presentation_generation;
    require(tb_display_lifecycle_note_presented_frame(
                &state, first_generation),
            "fresh current-generation frame is accepted");
    require(tb_display_lifecycle_may_expose_pixels(&state) &&
                tb_display_lifecycle_may_hide_cursor(&state),
            "fresh gated frame enables pixels and cursor ownership");

    require(tb_display_lifecycle_apply_source(&state, 0, 8) ==
                TB_DISPLAY_LIFECYCLE_APPLIED,
            "new source sleep epoch applies");
    require(!tb_display_lifecycle_accepts_frames(&state) &&
                !tb_display_lifecycle_wants_display_power(&state) &&
                !tb_display_lifecycle_may_hide_cursor(&state),
            "source sleep closes frame, power, and cursor gates");
    require(tb_display_lifecycle_apply_source(&state, 0, 8) ==
                TB_DISPLAY_LIFECYCLE_DUPLICATE,
            "duplicate sleep is idempotent");
    require(tb_display_lifecycle_apply_source(&state, 1, 7) ==
                TB_DISPLAY_LIFECYCLE_STALE,
            "stale wake cannot reverse newer sleep");
    require(!tb_display_lifecycle_note_presented_frame(
                &state, first_generation),
            "pre-sleep frame generation cannot unblank");

    require(tb_display_lifecycle_apply_source(&state, 1, 9) ==
                TB_DISPLAY_LIFECYCLE_APPLIED,
            "new wake applies");
    require(tb_display_lifecycle_accepts_frames(&state),
            "wake resumes whole-frame admission");
    require(!tb_display_lifecycle_may_expose_pixels(&state),
            "wake remains black until a new frame presents");
    require(tb_display_lifecycle_note_presented_frame(
                &state, state.presentation_generation),
            "current wake frame unblanks");

    struct tb_display_lifecycle barrier;
    tb_display_lifecycle_init(&barrier, 0);
    (void)tb_display_lifecycle_set_receiver_surface(&barrier, 1);
    const uint64_t old_receiver_epoch = barrier.receiver_epoch;
    require(tb_display_lifecycle_ack_receiver_epoch(
                &barrier, old_receiver_epoch) ==
                TB_DISPLAY_LIFECYCLE_APPLIED,
            "initial cross-direction barrier applies");
    (void)tb_display_lifecycle_set_receiver_surface(&barrier, 0);
    (void)tb_display_lifecycle_set_receiver_surface(&barrier, 1);
    require(tb_display_lifecycle_ack_receiver_epoch(
                &barrier, old_receiver_epoch) ==
                TB_DISPLAY_LIFECYCLE_STALE &&
                !tb_display_lifecycle_accepts_frames(&barrier),
            "pre-pause receiver acknowledgement cannot admit queued frames");
    require(tb_display_lifecycle_ack_receiver_epoch(
                &barrier, barrier.receiver_epoch) ==
                TB_DISPLAY_LIFECYCLE_APPLIED &&
                tb_display_lifecycle_accepts_frames(&barrier),
            "current receiver acknowledgement opens the frame barrier");

    int value = -1;
    uint64_t epoch = 0;
    const char *ordered = "{\"epoch\":42, \"awake\": false}";
    require(tb_display_lifecycle_parse_state_json(
                (const uint8_t *)ordered, strlen(ordered),
                "awake", &value, &epoch) &&
                !value && epoch == 42,
            "wire parser is independent of JSON key order");
    const char *overflow =
        "{\"awake\":true,\"epoch\":18446744073709551616}";
    require(!tb_display_lifecycle_parse_state_json(
                (const uint8_t *)overflow, strlen(overflow),
                "awake", &value, &epoch),
            "overflow epoch is rejected");
    const char *negative_epoch = "{\"awake\":true,\"epoch\":-1}";
    require(!tb_display_lifecycle_parse_state_json(
                (const uint8_t *)negative_epoch, strlen(negative_epoch),
                "awake", &value, &epoch),
            "negative epoch is rejected instead of becoming UINT64_MAX");
    const char *signed_epoch = "{\"awake\":true,\"epoch\":+1}";
    require(!tb_display_lifecycle_parse_state_json(
                (const uint8_t *)signed_epoch, strlen(signed_epoch),
                "awake", &value, &epoch),
            "explicitly signed epoch is rejected");
    const char *capability_only =
        "{\"awake\":true,\"epoch\":1,\"receiverEpoch\":0}";
    require(tb_display_lifecycle_parse_uint64_json(
                (const uint8_t *)capability_only,
                strlen(capability_only),
                "receiverEpoch", &epoch) && epoch == 0,
            "zero receiver epoch marks capability before the first barrier");
    const char *negative_receiver_epoch =
        "{\"awake\":true,\"epoch\":1,\"receiverEpoch\":-1}";
    require(!tb_display_lifecycle_parse_uint64_json(
                (const uint8_t *)negative_receiver_epoch,
                strlen(negative_receiver_epoch),
                "receiverEpoch", &epoch),
            "negative receiver epoch is rejected");

    /* A fresh connection resets only peer state so an unknown/old sender
     * retains the historical source-awake behavior. */
    (void)tb_display_lifecycle_apply_source(&state, 0, 99);
    tb_display_lifecycle_begin_stream(&state);
    require(state.source_awake && state.source_epoch == 0,
            "unknown peer compatibility defaults source awake");
    require(tb_display_lifecycle_assume_legacy_peer(&state),
            "unknown peer may cross the compatibility barrier on first frame");
    require(tb_display_lifecycle_accepts_frames(&state),
            "legacy peer resumes without lifecycle packets");
    require(!tb_display_lifecycle_may_expose_pixels(&state),
            "new stream still requires a fresh frame");

    printf("display lifecycle passed (epochs, compatibility, power/cursor/fresh-frame gates)\n");
    return 0;
}
