#include "tb_pre_session.h"

enum {
    TB_PRE_SESSION_PACKET_HELLO = 0x10,
    TB_PRE_SESSION_PACKET_UI_LANGUAGE = 0x13,
    TB_PRE_SESSION_PACKET_TEST_DATA = 0x40
};

enum tb_pre_session_action tb_pre_session_classify(
    int probe_started,
    uint32_t packet_length,
    uint8_t packet_type) {
    if (packet_length < 1 ||
        packet_length > TB_PRE_SESSION_MAX_PACKET_LENGTH) {
        return TB_PRE_SESSION_REJECT;
    }
    if (probe_started) {
        return packet_type == TB_PRE_SESSION_PACKET_TEST_DATA
            ? TB_PRE_SESSION_DISCARD_TEST_DATA
            : TB_PRE_SESSION_REJECT;
    }
    if (packet_type == TB_PRE_SESSION_PACKET_TEST_DATA) {
        return TB_PRE_SESSION_DISCARD_TEST_DATA;
    }
    if (packet_length > TB_PRE_SESSION_MAX_CONTROL_PACKET_LENGTH) {
        return TB_PRE_SESSION_REJECT;
    }
    if (packet_type == TB_PRE_SESSION_PACKET_HELLO) {
        return TB_PRE_SESSION_PROMOTE_HELLO;
    }
    if (packet_type == TB_PRE_SESSION_PACKET_UI_LANGUAGE) {
        return TB_PRE_SESSION_CLOSE_AUXILIARY;
    }
    return TB_PRE_SESSION_REJECT;
}

int tb_pre_session_is_ipv4_link_local(uint32_t host_address) {
    return (host_address & 0xFFFF0000u) == 0xA9FE0000u;
}
