#include "tb_display_lifecycle.h"

#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void tb_display_lifecycle_invalidate_frame(
    struct tb_display_lifecycle *state) {
    state->fresh_frame_presented = 0;
    state->presentation_generation++;
    if (state->presentation_generation == 0) {
        state->presentation_generation = 1;
    }
}

void tb_display_lifecycle_init(struct tb_display_lifecycle *state,
                               int receiver_surface_available) {
    if (!state) return;
    memset(state, 0, sizeof(*state));
    state->source_awake = 1; /* compatibility with senders before 0x3A */
    state->receiver_surface_available =
        receiver_surface_available != 0;
    state->receiver_epoch_acknowledged = 0;
    state->receiver_epoch = 1;
    state->presentation_generation = 1;
}

enum tb_display_lifecycle_update tb_display_lifecycle_apply_source(
    struct tb_display_lifecycle *state,
    int awake,
    uint64_t epoch) {
    if (!state || epoch == 0) return TB_DISPLAY_LIFECYCLE_INVALID;
    const int normalized = awake != 0;
    if (epoch < state->source_epoch) return TB_DISPLAY_LIFECYCLE_STALE;
    if (epoch == state->source_epoch) {
        return normalized == state->source_awake
            ? TB_DISPLAY_LIFECYCLE_DUPLICATE
            : TB_DISPLAY_LIFECYCLE_STALE;
    }
    state->source_epoch = epoch;
    state->source_awake = normalized;
    tb_display_lifecycle_invalidate_frame(state);
    return TB_DISPLAY_LIFECYCLE_APPLIED;
}

enum tb_display_lifecycle_update tb_display_lifecycle_set_receiver_surface(
    struct tb_display_lifecycle *state,
    int available) {
    if (!state) return TB_DISPLAY_LIFECYCLE_INVALID;
    const int normalized = available != 0;
    if (normalized == state->receiver_surface_available) {
        return TB_DISPLAY_LIFECYCLE_DUPLICATE;
    }
    uint64_t next_epoch = state->receiver_epoch + 1;
    if (next_epoch == 0) return TB_DISPLAY_LIFECYCLE_INVALID;
    return tb_display_lifecycle_publish_receiver_surface(
        state, normalized, next_epoch);
}

enum tb_display_lifecycle_update tb_display_lifecycle_publish_receiver_surface(
    struct tb_display_lifecycle *state,
    int available,
    uint64_t epoch) {
    if (!state || epoch == 0) return TB_DISPLAY_LIFECYCLE_INVALID;
    const int normalized = available != 0;
    if (epoch < state->receiver_epoch) return TB_DISPLAY_LIFECYCLE_STALE;
    if (epoch == state->receiver_epoch) {
        return normalized == state->receiver_surface_available
            ? TB_DISPLAY_LIFECYCLE_DUPLICATE
            : TB_DISPLAY_LIFECYCLE_STALE;
    }
    state->receiver_surface_available = normalized;
    state->receiver_epoch = epoch;
    state->receiver_epoch_acknowledged = 0;
    tb_display_lifecycle_invalidate_frame(state);
    return TB_DISPLAY_LIFECYCLE_APPLIED;
}

enum tb_display_lifecycle_update tb_display_lifecycle_ack_receiver_epoch(
    struct tb_display_lifecycle *state,
    uint64_t epoch) {
    if (!state || epoch == 0) return TB_DISPLAY_LIFECYCLE_INVALID;
    if (epoch != state->receiver_epoch) return TB_DISPLAY_LIFECYCLE_STALE;
    if (state->receiver_epoch_acknowledged) {
        return TB_DISPLAY_LIFECYCLE_DUPLICATE;
    }
    state->receiver_epoch_acknowledged = 1;
    return TB_DISPLAY_LIFECYCLE_APPLIED;
}

int tb_display_lifecycle_assume_legacy_peer(
    struct tb_display_lifecycle *state) {
    if (!state || state->source_epoch != 0 ||
        !state->receiver_surface_available) return 0;
    state->receiver_epoch_acknowledged = 1;
    return 1;
}

void tb_display_lifecycle_begin_stream(struct tb_display_lifecycle *state) {
    if (!state) return;
    /* A new connection may be an older sender that never emits 0x3A. Reset
     * only the peer-owned source half to its legacy-compatible default; a
     * capable sender's first epoch packet immediately replaces it. */
    state->source_awake = 1;
    state->source_epoch = 0;
    state->receiver_epoch_acknowledged = 0;
    tb_display_lifecycle_invalidate_frame(state);
}

void tb_display_lifecycle_end_stream(struct tb_display_lifecycle *state) {
    if (!state) return;
    tb_display_lifecycle_invalidate_frame(state);
}

int tb_display_lifecycle_note_presented_frame(
    struct tb_display_lifecycle *state,
    uint64_t generation) {
    if (!state || generation != state->presentation_generation ||
        !tb_display_lifecycle_accepts_frames(state)) {
        return 0;
    }
    if (state->fresh_frame_presented) return 0;
    state->fresh_frame_presented = 1;
    return 1;
}

int tb_display_lifecycle_accepts_frames(
    const struct tb_display_lifecycle *state) {
    return state && state->source_awake &&
        state->receiver_surface_available &&
        state->receiver_epoch_acknowledged;
}

int tb_display_lifecycle_wants_display_power(
    const struct tb_display_lifecycle *state) {
    return state && state->source_awake &&
        state->receiver_surface_available;
}

int tb_display_lifecycle_may_expose_pixels(
    const struct tb_display_lifecycle *state) {
    return tb_display_lifecycle_accepts_frames(state) &&
        state->fresh_frame_presented;
}

int tb_display_lifecycle_may_hide_cursor(
    const struct tb_display_lifecycle *state) {
    return tb_display_lifecycle_may_expose_pixels(state);
}

static const char *find_json_key(const char *json, const char *key) {
    char token[80];
    const int written = snprintf(token, sizeof(token), "\"%s\"", key);
    if (written <= 0 || (size_t)written >= sizeof(token)) return NULL;
    const char *found = strstr(json, token);
    if (!found) return NULL;
    found += (size_t)written;
    while (isspace((unsigned char)*found)) found++;
    if (*found++ != ':') return NULL;
    while (isspace((unsigned char)*found)) found++;
    return found;
}

int tb_display_lifecycle_parse_state_json(
    const uint8_t *payload,
    size_t payload_length,
    const char *boolean_key,
    int *value,
    uint64_t *epoch) {
    if (!payload || !boolean_key || !value || !epoch ||
        payload_length == 0 || payload_length > 1024) {
        return 0;
    }
    char json[1025];
    memcpy(json, payload, payload_length);
    json[payload_length] = '\0';

    const char *boolean_value = find_json_key(json, boolean_key);
    const char *epoch_value = find_json_key(json, "epoch");
    if (!boolean_value || !epoch_value) return 0;
    int parsed_value;
    const char *boolean_end = NULL;
    if (strncmp(boolean_value, "true", 4) == 0) {
        parsed_value = 1;
        boolean_end = boolean_value + 4;
    } else if (strncmp(boolean_value, "false", 5) == 0) {
        parsed_value = 0;
        boolean_end = boolean_value + 5;
    } else {
        return 0;
    }
    while (isspace((unsigned char)*boolean_end)) boolean_end++;
    if (*boolean_end != ',' && *boolean_end != '}' &&
        *boolean_end != '\0') return 0;

    errno = 0;
    char *end = NULL;
    /* JSON uint64 values are decimal digits only. strtoull deliberately accepts
     * a leading sign; in particular, "-1" becomes ULLONG_MAX and would poison
     * the monotonic epoch so every later legitimate transition looked stale. */
    if (!isdigit((unsigned char)*epoch_value)) return 0;
    const unsigned long long parsed_epoch =
        strtoull(epoch_value, &end, 10);
    if (errno == ERANGE || end == epoch_value || parsed_epoch == 0) return 0;
    while (isspace((unsigned char)*end)) end++;
    if (*end != ',' && *end != '}' && *end != '\0') return 0;

    *value = parsed_value;
    *epoch = (uint64_t)parsed_epoch;
    return 1;
}

int tb_display_lifecycle_parse_uint64_json(
    const uint8_t *payload,
    size_t payload_length,
    const char *key,
    uint64_t *value) {
    if (!payload || !key || !value || payload_length == 0 ||
        payload_length > 1024) return 0;
    char json[1025];
    memcpy(json, payload, payload_length);
    json[payload_length] = '\0';
    const char *number = find_json_key(json, key);
    if (!number) return 0;
    errno = 0;
    char *end = NULL;
    if (!isdigit((unsigned char)*number)) return 0;
    const unsigned long long parsed = strtoull(number, &end, 10);
    if (errno == ERANGE || end == number) return 0;
    while (isspace((unsigned char)*end)) end++;
    if (*end != ',' && *end != '}' && *end != '\0') return 0;
    *value = (uint64_t)parsed;
    return 1;
}
