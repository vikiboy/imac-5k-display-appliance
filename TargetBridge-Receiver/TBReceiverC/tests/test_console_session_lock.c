#include "tb_console_session_lock.h"

#include <assert.h>
#include <stdbool.h>
#include <stdio.h>

static CFDictionaryRef make_session(
    int64_t uid,
    bool on_console,
    const char *lock_key,
    const bool *locked) {
    CFNumberRef uid_number = CFNumberCreate(
        kCFAllocatorDefault, kCFNumberSInt64Type, &uid);
    const void *keys[3] = {
        CFSTR("kCGSSessionUserIDKey"),
        CFSTR("kCGSSessionOnConsoleKey"),
        NULL
    };
    const void *values[3] = {
        uid_number,
        on_console ? kCFBooleanTrue : kCFBooleanFalse,
        NULL
    };
    CFIndex count = 2;
    CFStringRef lock_key_ref = NULL;
    if (lock_key && locked) {
        lock_key_ref = CFStringCreateWithCString(
            kCFAllocatorDefault, lock_key, kCFStringEncodingUTF8);
        keys[count] = lock_key_ref;
        values[count] = *locked ? kCFBooleanTrue : kCFBooleanFalse;
        count++;
    }
    CFDictionaryRef result = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        values,
        count,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (lock_key_ref) CFRelease(lock_key_ref);
    CFRelease(uid_number);
    return result;
}

static CFArrayRef array_with_sessions(
    CFDictionaryRef first,
    CFDictionaryRef second) {
    const void *values[2] = {first, second};
    return CFArrayCreate(
        kCFAllocatorDefault,
        values,
        second ? 2 : 1,
        &kCFTypeArrayCallBacks);
}

int main(void) {
    const uid_t current_uid = 501;
    bool yes = true;
    bool no = false;

    assert(tb_console_session_lock_state_from_users(NULL, current_uid) ==
           TB_CONSOLE_SESSION_LOCK_UNKNOWN);

    CFDictionaryRef unlocked = make_session(501, true, NULL, NULL);
    CFArrayRef users = array_with_sessions(unlocked, NULL);
    assert(tb_console_session_lock_state_from_users(users, current_uid) ==
           TB_CONSOLE_SESSION_UNLOCKED);
    CFRelease(users);
    CFRelease(unlocked);

    CFDictionaryRef locked = make_session(
        501, true, "CGSSessionScreenIsLocked", &yes);
    users = array_with_sessions(locked, NULL);
    assert(tb_console_session_lock_state_from_users(users, current_uid) ==
           TB_CONSOLE_SESSION_LOCKED);
    CFRelease(users);
    CFRelease(locked);

    CFDictionaryRef explicit_unlocked = make_session(
        501, true, "kCGSSessionScreenIsLocked", &no);
    users = array_with_sessions(explicit_unlocked, NULL);
    assert(tb_console_session_lock_state_from_users(users, current_uid) ==
           TB_CONSOLE_SESSION_UNLOCKED);
    CFRelease(users);
    CFRelease(explicit_unlocked);

    locked = make_session(501, true, "CGSSessionScreenIsLocked", &yes);
    CFMutableDictionaryRef conflicting = CFDictionaryCreateMutableCopy(
        kCFAllocatorDefault, 0, locked);
    CFDictionarySetValue(
        conflicting, CFSTR("kCGSSessionScreenIsLocked"), kCFBooleanFalse);
    users = array_with_sessions(conflicting, NULL);
    assert(tb_console_session_lock_state_from_users(users, current_uid) ==
           TB_CONSOLE_SESSION_LOCK_UNKNOWN);
    CFRelease(users);
    CFRelease(conflicting);
    CFRelease(locked);

    unlocked = make_session(501, true, NULL, NULL);
    CFMutableDictionaryRef malformed = CFDictionaryCreateMutableCopy(
        kCFAllocatorDefault, 0, unlocked);
    CFDictionarySetValue(
        malformed, CFSTR("CGSSessionScreenIsLocked"), CFSTR("yes"));
    users = array_with_sessions(malformed, NULL);
    assert(tb_console_session_lock_state_from_users(users, current_uid) ==
           TB_CONSOLE_SESSION_LOCK_UNKNOWN);
    CFRelease(users);
    CFRelease(malformed);
    CFRelease(unlocked);

    CFDictionaryRef other_locked = make_session(
        502, true, "CGSSessionScreenIsLocked", &yes);
    unlocked = make_session(501, true, NULL, NULL);
    users = array_with_sessions(other_locked, unlocked);
    assert(tb_console_session_lock_state_from_users(users, current_uid) ==
           TB_CONSOLE_SESSION_UNLOCKED);
    CFRelease(users);
    CFRelease(other_locked);
    CFRelease(unlocked);

    other_locked = make_session(
        501, true, "CGSSessionScreenIsLocked", &yes);
    unlocked = make_session(501, true, NULL, NULL);
    users = array_with_sessions(unlocked, other_locked);
    assert(tb_console_session_lock_state_from_users(users, current_uid) ==
           TB_CONSOLE_SESSION_LOCKED);
    CFRelease(users);
    CFRelease(other_locked);
    CFRelease(unlocked);

    CFDictionaryRef off_console = make_session(501, false, NULL, NULL);
    users = array_with_sessions(off_console, NULL);
    assert(tb_console_session_lock_state_from_users(users, current_uid) ==
           TB_CONSOLE_SESSION_LOCK_UNKNOWN);
    CFRelease(users);
    CFRelease(off_console);

    CFDictionaryRef oversized_uid = make_session(
        INT64_C(1099511628277), true, NULL, NULL);
    users = array_with_sessions(oversized_uid, NULL);
    assert(tb_console_session_lock_state_from_users(users, current_uid) ==
           TB_CONSOLE_SESSION_LOCK_UNKNOWN);
    CFRelease(users);
    CFRelease(oversized_uid);

    puts("console session lock tests passed");
    return 0;
}
