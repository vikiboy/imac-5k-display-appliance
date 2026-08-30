#include "tb_power_lifecycle.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/pwr_mgt/IOPMLib.h>

#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

enum fake_kind {
    FAKE_SYSTEM,
    FAKE_DISPLAY,
    FAKE_ACTIVITY
};

struct fake_record {
    IOPMAssertionID id;
    enum fake_kind kind;
    bool active;
};

static struct fake_record records[64];
static size_t record_count;
static IOPMAssertionID next_id;
static int system_create_count;
static int display_create_count;
static int activity_declare_count;
static int release_count;
static enum fake_kind release_order[64];
static int active_system;
static int active_display;
static int active_activity;
static int max_active_display;
static int max_active_activity;
static bool fail_system_create;
static bool fail_display_create;
static bool fail_activity_declare;
static bool populate_id_on_failure;
static int release_failures_remaining;

static void reset_fake(void) {
    memset(records, 0, sizeof(records));
    memset(release_order, 0, sizeof(release_order));
    record_count = 0;
    next_id = 100;
    system_create_count = 0;
    display_create_count = 0;
    activity_declare_count = 0;
    release_count = 0;
    active_system = 0;
    active_display = 0;
    active_activity = 0;
    max_active_display = 0;
    max_active_activity = 0;
    fail_system_create = false;
    fail_display_create = false;
    fail_activity_declare = false;
    populate_id_on_failure = false;
    release_failures_remaining = 0;
}

static IOPMAssertionID record_create(enum fake_kind kind) {
    assert(record_count < sizeof(records) / sizeof(records[0]));
    const IOPMAssertionID id = next_id++;
    records[record_count++] = (struct fake_record){id, kind, true};
    if (kind == FAKE_SYSTEM) active_system++;
    if (kind == FAKE_DISPLAY) {
        active_display++;
        if (active_display > max_active_display) {
            max_active_display = active_display;
        }
    }
    if (kind == FAKE_ACTIVITY) {
        active_activity++;
        if (active_activity > max_active_activity) {
            max_active_activity = active_activity;
        }
    }
    return id;
}

IOReturn IOPMAssertionCreateWithName(CFStringRef assertionType,
                                     IOPMAssertionLevel assertionLevel,
                                     CFStringRef assertionName,
                                     IOPMAssertionID *assertionID) {
    (void)assertionLevel;
    (void)assertionName;
    assert(assertionID != NULL);
    const bool isDisplay = CFEqual(
        assertionType, kIOPMAssertionTypePreventUserIdleDisplaySleep);
    const enum fake_kind kind = isDisplay ? FAKE_DISPLAY : FAKE_SYSTEM;
    if (isDisplay) {
        display_create_count++;
    } else {
        system_create_count++;
    }

    const bool fail = isDisplay ? fail_display_create : fail_system_create;
    if (fail) {
        *assertionID = populate_id_on_failure
            ? record_create(kind)
            : kIOPMNullAssertionID;
        return kIOReturnError;
    }
    *assertionID = record_create(kind);
    return kIOReturnSuccess;
}

IOReturn IOPMAssertionDeclareUserActivity(CFStringRef assertionName,
                                          IOPMUserActiveType userType,
                                          IOPMAssertionID *assertionID) {
    (void)assertionName;
    assert(userType == kIOPMUserActiveRemote);
    assert(assertionID != NULL);
    activity_declare_count++;
    if (fail_activity_declare) {
        *assertionID = populate_id_on_failure
            ? record_create(FAKE_ACTIVITY)
            : kIOPMNullAssertionID;
        return kIOReturnError;
    }
    *assertionID = record_create(FAKE_ACTIVITY);
    return kIOReturnSuccess;
}

IOReturn IOPMAssertionRelease(IOPMAssertionID assertionID) {
    for (size_t i = 0; i < record_count; i++) {
        if (records[i].id != assertionID) continue;
        assert(records[i].active);
        if (release_failures_remaining > 0) {
            release_failures_remaining--;
            return kIOReturnError;
        }
        records[i].active = false;
        assert(release_count < (int)(sizeof(release_order) /
                                    sizeof(release_order[0])));
        release_order[release_count++] = records[i].kind;
        if (records[i].kind == FAKE_SYSTEM) active_system--;
        if (records[i].kind == FAKE_DISPLAY) active_display--;
        if (records[i].kind == FAKE_ACTIVITY) active_activity--;
        return kIOReturnSuccess;
    }
    assert(!"released an unknown assertion ID");
    return kIOReturnError;
}

static void assert_no_session_assertions(const struct tb_power_lifecycle *p) {
    assert(p->display_sleep_assertion == kIOPMNullAssertionID);
    assert(p->user_activity_assertion == kIOPMNullAssertionID);
    assert(active_display == 0);
    assert(active_activity == 0);
}

static void test_one_shot_session_and_idempotent_end(void) {
    reset_fake();
    struct tb_power_lifecycle p;
    assert(tb_power_lifecycle_start(&p) == 0);
    assert(active_system == 1);
    assert(tb_power_lifecycle_begin_session(&p) == 0);
    assert(display_create_count == 1);
    assert(activity_declare_count == 1);
    assert(active_display == 1);
    assert(active_activity == 1);

    /* No frame/heartbeat API exists: a live session remains one-shot. */
    assert(activity_declare_count == 1);
    tb_power_lifecycle_end_session(&p);
    assert_no_session_assertions(&p);
    assert(release_order[0] == FAKE_ACTIVITY);
    assert(release_order[1] == FAKE_DISPLAY);
    const int releases = release_count;
    tb_power_lifecycle_end_session(&p);
    assert(release_count == releases);
    tb_power_lifecycle_stop(&p);
    assert(active_system == 0);
}

static void test_reconnect_never_overlaps_assertions(void) {
    reset_fake();
    struct tb_power_lifecycle p;
    assert(tb_power_lifecycle_start(&p) == 0);
    for (int i = 0; i < 25; i++) {
        assert(tb_power_lifecycle_begin_session(&p) == 0);
        assert(active_display == 1);
        assert(active_activity == 1);
    }
    assert(display_create_count == 25);
    assert(activity_declare_count == 25);
    assert(max_active_display == 1);
    assert(max_active_activity == 1);
    tb_power_lifecycle_stop(&p);
    assert(active_system == 0);
    assert_no_session_assertions(&p);
}

static void test_failure_rollbacks(void) {
    reset_fake();
    struct tb_power_lifecycle p;
    assert(tb_power_lifecycle_start(&p) == 0);
    fail_display_create = true;
    populate_id_on_failure = true;
    assert(tb_power_lifecycle_begin_session(&p) == -1);
    assert_no_session_assertions(&p);
    fail_display_create = false;
    fail_activity_declare = true;
    assert(tb_power_lifecycle_begin_session(&p) == -1);
    assert_no_session_assertions(&p);
    tb_power_lifecycle_stop(&p);
    assert(active_system == 0);

    reset_fake();
    fail_system_create = true;
    populate_id_on_failure = true;
    assert(tb_power_lifecycle_start(&p) == -1);
    assert(active_system == 0);
    assert_no_session_assertions(&p);
}

static void test_release_failure_is_retained_and_retried(void) {
    reset_fake();
    struct tb_power_lifecycle p;
    assert(tb_power_lifecycle_start(&p) == 0);
    assert(tb_power_lifecycle_begin_session(&p) == 0);
    const int creates_before_failure = display_create_count;
    const int declarations_before_failure = activity_declare_count;

    /* The first release (UserIsActive) fails. Display release still succeeds,
     * and the failed ID remains owned for a retry. */
    release_failures_remaining = 1;
    tb_power_lifecycle_end_session(&p);
    assert(p.user_activity_assertion != kIOPMNullAssertionID);
    assert(p.display_sleep_assertion == kIOPMNullAssertionID);
    assert(active_activity == 1);
    assert(active_display == 0);

    /* If cleanup is still failing, a new session must not overwrite the live
     * ID or create another pair of assertions. */
    release_failures_remaining = 1;
    assert(tb_power_lifecycle_begin_session(&p) == -1);
    assert(display_create_count == creates_before_failure);
    assert(activity_declare_count == declarations_before_failure);
    assert(active_activity == 1);
    assert(max_active_activity == 1);

    /* A later retry succeeds, after which reconnect can safely create exactly
     * one new session pair. */
    assert(tb_power_lifecycle_begin_session(&p) == 0);
    assert(active_display == 1);
    assert(active_activity == 1);
    assert(max_active_display == 1);
    assert(max_active_activity == 1);

    /* Stop also retries a failed session release before releasing system
     * availability; one more explicit stop finishes any retained ID. */
    release_failures_remaining = 1;
    tb_power_lifecycle_stop(&p);
    assert(p.user_activity_assertion != kIOPMNullAssertionID);
    assert(active_system == 0);
    tb_power_lifecycle_stop(&p);
    assert_no_session_assertions(&p);
}

int main(void) {
    test_one_shot_session_and_idempotent_end();
    test_reconnect_never_overlaps_assertions();
    test_failure_rollbacks();
    test_release_failure_is_retained_and_retried();
    puts("power lifecycle tests passed");
    return 0;
}
