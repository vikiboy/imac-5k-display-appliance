#include "tb_pre_session.h"

#include <stdio.h>

static unsigned checks;
static unsigned failures;

#define CHECK(condition) do { \
    checks++; \
    if (!(condition)) { \
        failures++; \
        fprintf(stderr, "pre-session test failed at line %d: %s\n", \
                __LINE__, #condition); \
    } \
} while (0)

int main(void) {
    CHECK(tb_pre_session_classify(0, 128, 0x10) ==
          TB_PRE_SESSION_PROMOTE_HELLO);
    CHECK(tb_pre_session_classify(
              0, TB_PRE_SESSION_MAX_CONTROL_PACKET_LENGTH, 0x10) ==
          TB_PRE_SESSION_PROMOTE_HELLO);
    CHECK(tb_pre_session_classify(
              0, TB_PRE_SESSION_MAX_CONTROL_PACKET_LENGTH + 1, 0x10) ==
          TB_PRE_SESSION_REJECT);
    CHECK(tb_pre_session_classify(0, 32, 0x13) ==
          TB_PRE_SESSION_CLOSE_AUXILIARY);

    CHECK(tb_pre_session_classify(0, 256 * 1024 + 1, 0x40) ==
          TB_PRE_SESSION_DISCARD_TEST_DATA);
    CHECK(tb_pre_session_classify(
              0, TB_PRE_SESSION_MAX_PACKET_LENGTH, 0x40) ==
          TB_PRE_SESSION_DISCARD_TEST_DATA);
    CHECK(tb_pre_session_classify(
              0, TB_PRE_SESSION_MAX_PACKET_LENGTH + 1, 0x40) ==
          TB_PRE_SESSION_REJECT);
    CHECK(tb_pre_session_classify(1, 256 * 1024 + 1, 0x40) ==
          TB_PRE_SESSION_DISCARD_TEST_DATA);
    CHECK(tb_pre_session_classify(1, 128, 0x10) ==
          TB_PRE_SESSION_REJECT);
    CHECK(tb_pre_session_classify(1, 32, 0x13) ==
          TB_PRE_SESSION_REJECT);
    CHECK(tb_pre_session_classify(0, 0, 0x40) ==
          TB_PRE_SESSION_REJECT);
    CHECK(tb_pre_session_classify(0, 1, 0xff) ==
          TB_PRE_SESSION_REJECT);
    CHECK(tb_pre_session_is_ipv4_link_local(0xA9FE0000u));
    CHECK(tb_pre_session_is_ipv4_link_local(0xA9FEFFFFu));
    CHECK(!tb_pre_session_is_ipv4_link_local(0xA9FDFFFFu));
    CHECK(!tb_pre_session_is_ipv4_link_local(0xC0A80101u));

    printf("pre-session classifier tests: %u checks, %u failures\n",
           checks, failures);
    return failures == 0 ? 0 : 1;
}
