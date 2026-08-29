#ifndef TB_PRE_SESSION_H
#define TB_PRE_SESSION_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TB_PRE_SESSION_MAX_PACKET_LENGTH (64u * 1024u * 1024u)
#define TB_PRE_SESSION_MAX_CONTROL_PACKET_LENGTH (64u * 1024u)

enum tb_pre_session_action {
    TB_PRE_SESSION_REJECT = 0,
    TB_PRE_SESSION_PROMOTE_HELLO = 1,
    TB_PRE_SESSION_CLOSE_AUXILIARY = 2,
    TB_PRE_SESSION_DISCARD_TEST_DATA = 3
};

/* packet_length includes the one-byte packet type. Once a peer begins a path
 * probe, only complete TEST_DATA packets remain legal on that connection. */
enum tb_pre_session_action tb_pre_session_classify(
    int probe_started,
    uint32_t packet_length,
    uint8_t packet_type);

/* Address is host byte order, matching ntohl(sockaddr_in.sin_addr.s_addr). */
int tb_pre_session_is_ipv4_link_local(uint32_t host_address);

#ifdef __cplusplus
}
#endif

#endif
