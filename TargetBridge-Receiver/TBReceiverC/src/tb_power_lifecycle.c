#include "tb_power_lifecycle.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/pwr_mgt/IOPMLib.h>

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

enum {
    TB_POWER_LOG_SYSTEM_CREATE = 1u << 0,
    TB_POWER_LOG_DISPLAY_CREATE = 1u << 1,
    TB_POWER_LOG_USER_ACTIVITY = 1u << 2,
    TB_POWER_LOG_SYSTEM_RELEASE = 1u << 3,
    TB_POWER_LOG_DISPLAY_RELEASE = 1u << 4,
    TB_POWER_LOG_ACTIVITY_RELEASE = 1u << 5
};

static void tb_power_log_error_once(struct tb_power_lifecycle *lifecycle,
                                    uint32_t bit,
                                    const char *operation,
                                    IOReturn result) {
    if (!lifecycle || (lifecycle->logged_error_mask & bit) != 0) return;
    lifecycle->logged_error_mask |= bit;
    fprintf(stderr,
            "TB_PROTOCOL_METAL power=%s result=failed ioReturn=0x%08x\n",
            operation,
            (unsigned int)result);
}

static bool tb_power_release(struct tb_power_lifecycle *lifecycle,
                             uint32_t *storedID,
                             uint32_t errorBit,
                             const char *operation) {
    if (!lifecycle || !storedID) return false;
    if (*storedID == kIOPMNullAssertionID) return true;
    const IOPMAssertionID assertionID = (IOPMAssertionID)*storedID;
    const IOReturn result = IOPMAssertionRelease(assertionID);
    if (result != kIOReturnSuccess) {
        /* Keep the ID live so a later teardown can retry. Forgetting it here
         * could leave a process-owned assertion active indefinitely. */
        tb_power_log_error_once(lifecycle, errorBit, operation, result);
        return false;
    }
    *storedID = kIOPMNullAssertionID;
    return true;
}

int tb_power_lifecycle_start(struct tb_power_lifecycle *lifecycle) {
    if (!lifecycle) return -1;
    memset(lifecycle, 0, sizeof(*lifecycle));

    IOPMAssertionID systemAssertion = kIOPMNullAssertionID;
    const IOReturn result = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleSystemSleep,
        kIOPMAssertionLevelOn,
        CFSTR("TargetBridge receiver available for a display connection"),
        &systemAssertion);
    lifecycle->system_sleep_assertion = (uint32_t)systemAssertion;
    if (result != kIOReturnSuccess ||
        systemAssertion == kIOPMNullAssertionID) {
        tb_power_log_error_once(
            lifecycle, TB_POWER_LOG_SYSTEM_CREATE,
            "system-idle-assertion-create", result);
        tb_power_release(
            lifecycle,
            &lifecycle->system_sleep_assertion,
            TB_POWER_LOG_SYSTEM_RELEASE,
            "system-idle-assertion-release");
        return -1;
    }
    fprintf(stderr,
            "TB_PROTOCOL_METAL power=system-idle-sleep-prevented "
            "display-idle-sleep=allowed\n");
    return 0;
}

int tb_power_lifecycle_begin_session(struct tb_power_lifecycle *lifecycle) {
    if (!lifecycle ||
        lifecycle->system_sleep_assertion == kIOPMNullAssertionID) {
        return -1;
    }

    /* A previous partially closed session must not leak an assertion into the
     * next connection. Both release helpers are idempotent. */
    tb_power_lifecycle_end_session(lifecycle);
    if (lifecycle->display_sleep_assertion != kIOPMNullAssertionID ||
        lifecycle->user_activity_assertion != kIOPMNullAssertionID) {
        /* Fail closed instead of overwriting an ID whose release failed. */
        return -1;
    }

    IOPMAssertionID displayAssertion = kIOPMNullAssertionID;
    IOReturn result = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleDisplaySleep,
        kIOPMAssertionLevelOn,
        CFSTR("TargetBridge active display session"),
        &displayAssertion);
    lifecycle->display_sleep_assertion = (uint32_t)displayAssertion;
    if (result != kIOReturnSuccess ||
        displayAssertion == kIOPMNullAssertionID) {
        tb_power_log_error_once(
            lifecycle, TB_POWER_LOG_DISPLAY_CREATE,
            "display-idle-assertion-create", result);
        tb_power_lifecycle_end_session(lifecycle);
        return -1;
    }

    /* This is a one-shot remote wake signal. The display assertion above owns
     * the long-lived awake state; repeating DeclareUserActivity on every
     * heartbeat is redundant and can cause framework allocation churn. */
    IOPMAssertionID activityAssertion =
        kIOPMNullAssertionID;
    result = IOPMAssertionDeclareUserActivity(
        CFSTR("TargetBridge display session active"),
        kIOPMUserActiveRemote,
        &activityAssertion);
    /* Retain even an unexpectedly populated failure result so rollback can
     * release every ID returned by IOKit. */
    lifecycle->user_activity_assertion = (uint32_t)activityAssertion;
    if (result != kIOReturnSuccess ||
        activityAssertion == kIOPMNullAssertionID) {
        tb_power_log_error_once(
            lifecycle, TB_POWER_LOG_USER_ACTIVITY,
            "panel-wake-user-activity", result);
        tb_power_lifecycle_end_session(lifecycle);
        return -1;
    }
    return 0;
}

void tb_power_lifecycle_end_session(struct tb_power_lifecycle *lifecycle) {
    if (!lifecycle) return;
    tb_power_release(
        lifecycle,
        &lifecycle->user_activity_assertion,
        TB_POWER_LOG_ACTIVITY_RELEASE,
        "user-activity-assertion-release");
    tb_power_release(
        lifecycle,
        &lifecycle->display_sleep_assertion,
        TB_POWER_LOG_DISPLAY_RELEASE,
        "display-idle-assertion-release");
}

void tb_power_lifecycle_stop(struct tb_power_lifecycle *lifecycle) {
    if (!lifecycle) return;
    tb_power_lifecycle_end_session(lifecycle);
    tb_power_release(
        lifecycle,
        &lifecycle->system_sleep_assertion,
        TB_POWER_LOG_SYSTEM_RELEASE,
        "system-idle-assertion-release");
}
