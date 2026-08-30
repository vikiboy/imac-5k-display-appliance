#include "tb_console_session_lock.h"

#include <IOKit/IOKitLib.h>
#include <stdbool.h>
#include <stdint.h>
#include <unistd.h>

static bool cf_boolean(CFTypeRef value, bool *result) {
    if (!value || CFGetTypeID(value) != CFBooleanGetTypeID()) return false;
    if (result) *result = CFBooleanGetValue((CFBooleanRef)value);
    return true;
}

static bool cf_uid(CFTypeRef value, uid_t *result) {
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) return false;
    int64_t uid = -1;
    if (!CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &uid) ||
        uid < 0 || (uint64_t)uid > (uint64_t)(uid_t)-1) {
        return false;
    }
    if (result) *result = (uid_t)uid;
    return true;
}

enum tb_console_session_lock_state tb_console_session_lock_state_from_users(
    CFTypeRef users,
    uid_t current_uid) {
    if (!users || CFGetTypeID(users) != CFArrayGetTypeID()) {
        return TB_CONSOLE_SESSION_LOCK_UNKNOWN;
    }

    const CFStringRef uid_keys[] = {
        CFSTR("kCGSSessionUserIDKey"),
        CFSTR("kCGSessionUserIDKey")
    };
    const CFStringRef lock_keys[] = {
        CFSTR("CGSSessionScreenIsLocked"),
        CFSTR("kCGSSessionScreenIsLocked")
    };
    bool saw_locked = false;
    bool saw_unlocked = false;
    bool saw_invalid = false;
    const CFIndex count = CFArrayGetCount((CFArrayRef)users);
    for (CFIndex index = 0; index < count; index++) {
        CFTypeRef entry = CFArrayGetValueAtIndex((CFArrayRef)users, index);
        if (!entry || CFGetTypeID(entry) != CFDictionaryGetTypeID()) continue;
        CFDictionaryRef session = (CFDictionaryRef)entry;

        uid_t uid = (uid_t)-1;
        bool has_uid = false;
        for (size_t key = 0; key < sizeof(uid_keys) / sizeof(uid_keys[0]); key++) {
            if (cf_uid(CFDictionaryGetValue(session, uid_keys[key]), &uid)) {
                has_uid = true;
                break;
            }
        }
        if (!has_uid || uid != current_uid) continue;

        bool on_console = false;
        if (!cf_boolean(CFDictionaryGetValue(
                session, CFSTR("kCGSSessionOnConsoleKey")), &on_console) ||
            !on_console) {
            continue;
        }

        bool found_lock_field = false;
        bool parsed_locked = false;
        for (size_t key = 0;
             key < sizeof(lock_keys) / sizeof(lock_keys[0]);
             key++) {
            if (!CFDictionaryContainsKey(session, lock_keys[key])) continue;
            bool locked = false;
            if (!cf_boolean(CFDictionaryGetValue(session, lock_keys[key]),
                            &locked)) {
                saw_invalid = true;
                found_lock_field = false;
                break;
            }
            if (found_lock_field && locked != parsed_locked) {
                saw_invalid = true;
                found_lock_field = false;
                break;
            }
            found_lock_field = true;
            parsed_locked = locked;
        }

        if (found_lock_field) {
            if (parsed_locked) saw_locked = true;
            else saw_unlocked = true;
        } else if (!saw_invalid) {
            /* On the tested macOS versions the key exists only while locked. */
            saw_unlocked = true;
        }
    }
    /* Locked dominates ambiguous duplicate records. Malformed evidence never
     * authorizes a surface, and contradictory unlocked/locked duplicates are
     * therefore treated as locked rather than depending on array order. */
    if (saw_locked) return TB_CONSOLE_SESSION_LOCKED;
    if (saw_invalid) return TB_CONSOLE_SESSION_LOCK_UNKNOWN;
    if (saw_unlocked) return TB_CONSOLE_SESSION_UNLOCKED;
    return TB_CONSOLE_SESSION_LOCK_UNKNOWN;
}

enum tb_console_session_lock_state tb_current_console_session_lock_state(void) {
    /* The documented default IOKit main/master port is MACH_PORT_NULL. Using
     * the value directly keeps this small helper deployable on macOS 11
     * without referencing the macOS-12 spelling of the constant. */
    io_registry_entry_t root = IORegistryGetRootEntry(MACH_PORT_NULL);
    if (root == IO_OBJECT_NULL) return TB_CONSOLE_SESSION_LOCK_UNKNOWN;
    CFTypeRef users = IORegistryEntryCreateCFProperty(
        root, CFSTR("IOConsoleUsers"), kCFAllocatorDefault, 0);
    IOObjectRelease(root);
    if (!users) return TB_CONSOLE_SESSION_LOCK_UNKNOWN;
    const enum tb_console_session_lock_state state =
        tb_console_session_lock_state_from_users(users, getuid());
    CFRelease(users);
    return state;
}
