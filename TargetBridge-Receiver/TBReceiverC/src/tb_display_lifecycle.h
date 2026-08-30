#ifndef TB_DISPLAY_LIFECYCLE_H
#define TB_DISPLAY_LIFECYCLE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum tb_display_lifecycle_update {
    TB_DISPLAY_LIFECYCLE_INVALID = -1,
    TB_DISPLAY_LIFECYCLE_DUPLICATE = 0,
    TB_DISPLAY_LIFECYCLE_APPLIED = 1,
    TB_DISPLAY_LIFECYCLE_STALE = 2
};

/* Pure control-plane reducer. Old senders are source-awake by default, while
 * the local receiver surface starts unavailable until public AppKit/workspace
 * state proves ownership. Every gate transition invalidates the prior fresh
 * frame so stale pixels can never uncover the surface after wake/unlock. */
struct tb_display_lifecycle {
    int source_awake;
    int receiver_surface_available;
    int receiver_epoch_acknowledged;
    int fresh_frame_presented;
    uint64_t source_epoch;
    uint64_t receiver_epoch;
    uint64_t presentation_generation;
};

void tb_display_lifecycle_init(struct tb_display_lifecycle *state,
                               int receiver_surface_available);

enum tb_display_lifecycle_update tb_display_lifecycle_apply_source(
    struct tb_display_lifecycle *state,
    int awake,
    uint64_t epoch);

enum tb_display_lifecycle_update tb_display_lifecycle_set_receiver_surface(
    struct tb_display_lifecycle *state,
    int available);

enum tb_display_lifecycle_update tb_display_lifecycle_publish_receiver_surface(
    struct tb_display_lifecycle *state,
    int available,
    uint64_t epoch);

enum tb_display_lifecycle_update tb_display_lifecycle_ack_receiver_epoch(
    struct tb_display_lifecycle *state,
    uint64_t epoch);

int tb_display_lifecycle_assume_legacy_peer(
    struct tb_display_lifecycle *state);

void tb_display_lifecycle_begin_stream(struct tb_display_lifecycle *state);
void tb_display_lifecycle_end_stream(struct tb_display_lifecycle *state);

/* The generation must have been sampled while accepting the frame. */
int tb_display_lifecycle_note_presented_frame(
    struct tb_display_lifecycle *state,
    uint64_t generation);

int tb_display_lifecycle_accepts_frames(
    const struct tb_display_lifecycle *state);
int tb_display_lifecycle_wants_display_power(
    const struct tb_display_lifecycle *state);
int tb_display_lifecycle_may_expose_pixels(
    const struct tb_display_lifecycle *state);
int tb_display_lifecycle_may_hide_cursor(
    const struct tb_display_lifecycle *state);

/* Parses a bounded JSON Boolean/epoch state without depending on key order.
 * The caller supplies the Boolean field name ("awake" or "available"). */
int tb_display_lifecycle_parse_state_json(
    const uint8_t *payload,
    size_t payload_length,
    const char *boolean_key,
    int *value,
    uint64_t *epoch);

int tb_display_lifecycle_parse_uint64_json(
    const uint8_t *payload,
    size_t payload_length,
    const char *key,
    uint64_t *value);

#ifdef __cplusplus
}
#endif

#endif
