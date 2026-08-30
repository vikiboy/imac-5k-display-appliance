#ifndef TB_CONSOLE_SESSION_LOCK_H
#define TB_CONSOLE_SESSION_LOCK_H

#include <CoreFoundation/CoreFoundation.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

enum tb_console_session_lock_state {
    TB_CONSOLE_SESSION_LOCK_UNKNOWN = 0,
    TB_CONSOLE_SESSION_UNLOCKED = 1,
    TB_CONSOLE_SESSION_LOCKED = 2
};

enum tb_console_session_lock_state tb_console_session_lock_state_from_users(
    CFTypeRef users,
    uid_t current_uid);

enum tb_console_session_lock_state tb_current_console_session_lock_state(void);

#ifdef __cplusplus
}
#endif

#endif
