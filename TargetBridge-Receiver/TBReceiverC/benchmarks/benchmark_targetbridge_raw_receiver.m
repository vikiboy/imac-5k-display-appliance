#import "raw_nv12.h"
#import "tb_appliance_surface_policy.h"
#import "tb_console_session_lock.h"
#import "tb_cursor_shield_view.h"
#import "tb_dpcm.h"
#import "tb_display_lifecycle.h"
#import "tb_native_metal_renderer.h"
#import "tb_power_lifecycle.h"
#import "tb_pre_session.h"
#import "tb_shutdown_gate.h"

#import <AppKit/AppKit.h>
#import <CoreGraphics/CGSession.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <os/log.h>

#include <arpa/inet.h>
#include <dispatch/dispatch.h>
#include <dns_sd.h>
#include <errno.h>
#include <ifaddrs.h>
#include <math.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

enum {
    TB_PACKET_DISPLAY_PROFILE = 0x11,
    TB_PACKET_VIDEO_PARAMETERS = 0x20,
    TB_PACKET_VIDEO_FRAME = 0x21,
    TB_PACKET_RAW_FRAME = 0x22,
    TB_PACKET_DPCM_FRAME = 0x25,
    TB_PACKET_RECEIVER_SURFACE_STATE = 0x39,
    TB_PACKET_SOURCE_DISPLAY_STATE = 0x3A,
    TB_MAX_PACKET_LENGTH = TB_PRE_SESSION_MAX_PACKET_LENGTH,
    TB_SERVE_PEER_IDLE_TIMEOUT_SECONDS = 15
};

struct tb_receiver_lifecycle_snapshot {
    pthread_mutex_t lock;
    bool receiver_surface_available;
    bool source_awake;
    bool frames_allowed;
    bool power_gate_failed;
    uint64_t receiver_epoch;
    uint64_t presentation_generation;
};

static void tb_receiver_lifecycle_snapshot_store(
    struct tb_receiver_lifecycle_snapshot *snapshot,
    bool receiver_surface_available,
    uint64_t receiver_epoch,
    bool source_awake,
    bool frames_allowed,
    uint64_t presentation_generation) {
    pthread_mutex_lock(&snapshot->lock);
    snapshot->receiver_surface_available = receiver_surface_available;
    snapshot->receiver_epoch = receiver_epoch;
    snapshot->source_awake = source_awake;
    snapshot->frames_allowed = frames_allowed;
    snapshot->presentation_generation = presentation_generation;
    pthread_mutex_unlock(&snapshot->lock);
}

static void tb_receiver_lifecycle_snapshot_load(
    struct tb_receiver_lifecycle_snapshot *snapshot,
    bool *receiver_surface_available,
    uint64_t *receiver_epoch,
    bool *source_awake,
    bool *frames_allowed,
    uint64_t *presentation_generation,
    bool *power_gate_failed) {
    pthread_mutex_lock(&snapshot->lock);
    if (receiver_surface_available) {
        *receiver_surface_available = snapshot->receiver_surface_available;
    }
    if (receiver_epoch) *receiver_epoch = snapshot->receiver_epoch;
    if (source_awake) *source_awake = snapshot->source_awake;
    if (frames_allowed) *frames_allowed = snapshot->frames_allowed;
    if (presentation_generation) {
        *presentation_generation = snapshot->presentation_generation;
    }
    if (power_gate_failed) *power_gate_failed = snapshot->power_gate_failed;
    pthread_mutex_unlock(&snapshot->lock);
}

static void tb_receiver_lifecycle_snapshot_set_power_failure(
    struct tb_receiver_lifecycle_snapshot *snapshot,
    bool failed) {
    pthread_mutex_lock(&snapshot->lock);
    snapshot->power_gate_failed = failed;
    pthread_mutex_unlock(&snapshot->lock);
}

static os_log_t receiver_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.targetbridge.receiver5k", "runtime");
    });
    return log;
}

/* launchd deliberately routes stdout/stderr to /dev/null. Keep a small set of
 * session-boundary facts in Apple's size-managed unified log so an automatic
 * launch remains diagnosable without creating a growing application log. */
static void receiver_diagnostic(os_log_type_t type,
                                const char *format,
                                ...) {
    char message[1024];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(message, sizeof(message), format, arguments);
    va_end(arguments);
    os_log_with_type(receiver_log(), type, "%{public}s", message);
}

/* CGDisplayHideCursor/ShowCursor maintain one process-global count; Apple's
 * display argument is retained for API compatibility but is not a scope. Do
 * not clear our balance flag until Core Graphics confirms the matching Show.
 */
static bool restore_global_cursor(CGDirectDisplayID displayID,
                                  bool *cursorHidden,
                                  const char *phase) {
    if (!cursorHidden || !*cursorHidden) return true;
    CGError lastError = kCGErrorFailure;
    for (unsigned int attempt = 1; attempt <= 2; attempt++) {
        lastError = CGDisplayShowCursor(displayID);
        if (lastError == kCGErrorSuccess) {
            *cursorHidden = false;
            receiver_diagnostic(
                OS_LOG_TYPE_DEFAULT,
                "%s globalCursor=restored apiDisplay=%u attempt=%u",
                phase,
                (unsigned int)displayID,
                attempt);
            return true;
        }
    }
    receiver_diagnostic(
        OS_LOG_TYPE_ERROR,
        "%s globalCursor=restore-failed apiDisplay=%u error=%d attempts=2",
        phase,
        (unsigned int)displayID,
        (int)lastError);
    return false;
}

/* Apple documents that CGDisplayHideCursor normally affects the system cursor
 * only when the caller is foreground. App activation is asynchronous, so a
 * success result before applicationDidBecomeActive is not sufficient. This
 * helper is called from foreground/key/wake callbacks and keeps one balanced
 * Core Graphics hide owned by the active display session. */
static bool ensure_global_cursor_hidden(CGDirectDisplayID displayID,
                                        bool *cursorHidden,
                                        const char *phase) {
    if (!cursorHidden || !NSApp.isActive) {
        receiver_diagnostic(
            OS_LOG_TYPE_DEFAULT,
            "%s globalCursor=hide-deferred appActive=%s",
            phase,
            NSApp.isActive ? "true" : "false");
        return false;
    }

    if (*cursorHidden) {
        const CGError showResult = CGDisplayShowCursor(displayID);
        if (showResult != kCGErrorSuccess) {
            receiver_diagnostic(
                OS_LOG_TYPE_ERROR,
                "%s globalCursor=reassert-show-failed error=%d",
                phase,
                (int)showResult);
            return false;
        }
        *cursorHidden = false;
    }

    const CGError hideResult = CGDisplayHideCursor(displayID);
    if (hideResult != kCGErrorSuccess) {
        receiver_diagnostic(
            OS_LOG_TYPE_ERROR,
            "%s globalCursor=hide-failed error=%d",
            phase,
            (int)hideResult);
        return false;
    }
    *cursorHidden = true;
    receiver_diagnostic(
        OS_LOG_TYPE_DEFAULT,
        "%s globalCursor=hidden appActive=true apiDisplay=%u",
        phase,
        (unsigned int)displayID);
    return true;
}

static dispatch_source_t termination_signal_source(
    int signalNumber,
    struct tb_shutdown_gate *shutdownGate) {
    dispatch_source_t source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_SIGNAL,
        (uintptr_t)signalNumber,
        0,
        dispatch_get_main_queue());
    if (!source) return nil;
    dispatch_source_set_event_handler(source, ^{
        if (tb_shutdown_gate_request(shutdownGate, signalNumber)) {
            receiver_diagnostic(
                OS_LOG_TYPE_DEFAULT,
                "shutdown=requested signal=%d admission=closed",
                signalNumber);
        }
    });
    dispatch_activate(source);
    return source;
}

@interface TBReceiverMenuController : NSObject
- (void)requestGracefulQuit:(id)sender;
@end

@implementation TBReceiverMenuController
- (void)requestGracefulQuit:(id)sender {
    (void)sender;
    // Reuse the same dispatch-signal shutdown path as launchd and Terminal.
    // Calling NSApp terminate: directly could bypass cursor, power, socket, and
    // bounded Metal cleanup while a session is active.
    if (kill(getpid(), SIGTERM) != 0) {
        [NSApp terminate:nil];
    }
}
@end

/* Borderless NSWindow instances do not become key/main by default. The idle
 * appliance has one native Options control, so make this specific panel
 * eligible for normal AppKit activation when the user clicks it. */
@interface TBApplianceWindow : NSWindow
@end

@implementation TBApplianceWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

static BOOL current_startup_gui_session_available(void) {
    CFDictionaryRef session = CGSessionCopyCurrentDictionary();
    if (!session) return NO;
    CFTypeRef onConsole = CFDictionaryGetValue(
        session, kCGSessionOnConsoleKey);
    CFTypeRef loginDone = CFDictionaryGetValue(
        session, kCGSessionLoginDoneKey);
    const BOOL available =
        onConsole && CFGetTypeID(onConsole) == CFBooleanGetTypeID() &&
        CFBooleanGetValue((CFBooleanRef)onConsole) &&
        loginDone && CFGetTypeID(loginDone) == CFBooleanGetTypeID() &&
        CFBooleanGetValue((CFBooleanRef)loginDone);
    CFRelease(session);
    if (!available) return NO;

    /* NSWorkspace supplies the dynamic authority. This read-only startup
     * snapshot closes its one blind spot: launchd can restart the receiver
     * after the session-resigned callback has already happened. The optional
     * IOConsoleUsers lock field is absent while unlocked on the tested iMac.
     * Missing or malformed startup evidence fails closed; once running, the
     * documented NSWorkspace notifications are the dynamic authority. */
    return tb_current_console_session_lock_state() ==
        TB_CONSOLE_SESSION_UNLOCKED;
}

@interface TBReceiverPresentationController : NSObject <NSApplicationDelegate>
- (instancetype)initWithWindow:(NSWindow *)window;
@property(nonatomic, getter=isStreamActive) BOOL streamActive;
@property(nonatomic, copy, nullable) dispatch_block_t cursorActivationHandler;
@property(nonatomic, copy, nullable) dispatch_block_t cursorDeactivationHandler;
@property(nonatomic, copy, nullable) dispatch_block_t privacyBlankHandler;
@property(nonatomic, copy, nullable) dispatch_block_t privacyResumeHandler;
@property(nonatomic, copy, nullable) BOOL (^displayPowerGateHandler)(BOOL active);
@property(nonatomic, copy, nullable) void (^lifecycleStateHandler)(
    BOOL receiverSurfaceAvailable,
    uint64_t receiverEpoch,
    BOOL sourceAwake,
    BOOL framesAllowed,
    uint64_t presentationGeneration);
- (void)requestCursorActivation;
- (enum tb_display_lifecycle_update)applySourceDisplayAwake:(BOOL)awake
                                                     epoch:(uint64_t)epoch
                                             receiverEpoch:(uint64_t)receiverEpoch;
- (BOOL)markFreshFramePresentedForGeneration:(uint64_t)generation;
- (BOOL)admitLegacyFrameForGeneration:(uint64_t *)generation;
- (void)refreshLifecycleState;
- (void)scheduleStartupSessionRevalidation;
- (void)performStartupSessionRevalidation:(NSUInteger)retryGeneration
                                  remaining:(NSUInteger)remaining;
- (void)invalidate;
@end

@implementation TBReceiverPresentationController {
    NSWindow *_window;
    id _screensDidWakeObserver;
    id _sessionDidBecomeActiveObserver;
    id _sessionDidResignActiveObserver;
    id _windowDidBecomeKeyObserver;
    id _windowDidResignKeyObserver;
    NSUInteger _activationRequestGeneration;
    NSUInteger _sessionTransitionGeneration;
    NSUInteger _startupSnapshotRetryGeneration;
    BOOL _guiSessionActive;
    BOOL _appForeground;
    BOOL _displayPowerActive;
    BOOL _lastReportedSurfaceAvailable;
    uint64_t _reportedSurfaceEpoch;
    struct tb_display_lifecycle _displayLifecycle;
}

- (instancetype)initWithWindow:(NSWindow *)window {
    self = [super init];
    if (!self) return nil;
    _window = window;
    /* Seed from the public CG session dictionary plus the optional read-only
     * console-lock snapshot so launch into an already active Aqua session
     * does not wait for a transition notification. Dynamic authority comes
     * from the public NSWorkspace/AppKit callbacks below. */
    _guiSessionActive = current_startup_gui_session_available();
    _appForeground = NSApp.isActive;
    tb_display_lifecycle_init(&_displayLifecycle, 0);
    _reportedSurfaceEpoch = 1;
    __weak TBReceiverPresentationController *weakSelf = self;
    _screensDidWakeObserver = [NSWorkspace.sharedWorkspace.notificationCenter
                addObserverForName:NSWorkspaceScreensDidWakeNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) {
        TBReceiverPresentationController *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!strongSelf->_guiSessionActive) {
            [strongSelf scheduleStartupSessionRevalidation];
            return;
        }
        [strongSelf presentWithoutActivation];
        if (strongSelf.streamActive) {
            [strongSelf requestCursorActivation];
        }
        [strongSelf refreshLifecycleState];
    }];
    _sessionDidBecomeActiveObserver =
        [NSWorkspace.sharedWorkspace.notificationCenter
            addObserverForName:NSWorkspaceSessionDidBecomeActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *notification) {
        TBReceiverPresentationController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_sessionTransitionGeneration += 1;
        strongSelf->_guiSessionActive = YES;
        receiver_diagnostic(
            OS_LOG_TYPE_DEFAULT,
            "gui-session=active stream=%s action=reclaim-surface",
            strongSelf.streamActive ? "true" : "false");
        [strongSelf presentWithoutActivation];
        [strongSelf refreshLifecycleState];
        if (strongSelf.streamActive) [strongSelf requestCursorActivation];
    }];
    _sessionDidResignActiveObserver =
        [NSWorkspace.sharedWorkspace.notificationCenter
            addObserverForName:NSWorkspaceSessionDidResignActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *notification) {
        TBReceiverPresentationController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_sessionTransitionGeneration += 1;
        strongSelf->_guiSessionActive = NO;
        strongSelf->_activationRequestGeneration += 1;
        [strongSelf refreshLifecycleState];
        receiver_diagnostic(
            OS_LOG_TYPE_DEFAULT,
            "gui-session=inactive stream=%s "
            "action=blank-surface-and-release-cursor",
            strongSelf.streamActive ? "true" : "false");
    }];
    _windowDidBecomeKeyObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:NSWindowDidBecomeKeyNotification
                    object:_window
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) {
        TBReceiverPresentationController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf reapplyCursorShield];
        [strongSelf refreshLifecycleState];
    }];
    _windowDidResignKeyObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:NSWindowDidResignKeyNotification
                    object:_window
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) {
        TBReceiverPresentationController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_activationRequestGeneration += 1;
        [strongSelf refreshLifecycleState];
        receiver_diagnostic(
            OS_LOG_TYPE_DEFAULT,
            "window=non-key stream=%s cursor=released surface=blank",
            strongSelf.streamActive ? "true" : "false");
        /* Do not make a window key reentrantly from its resign-key callback.
         * During app or secure-session deactivation NSApp can still report
         * active for this callback's turn. The generation check lets the
         * corresponding resign/session notification cancel this request;
         * ordinary same-app key loss is reclaimed on a later main-queue turn. */
        if (strongSelf.streamActive && strongSelf->_guiSessionActive &&
            NSApp.isActive) {
            const NSUInteger generation =
                strongSelf->_activationRequestGeneration;
            dispatch_after(
                dispatch_time(
                    DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                dispatch_get_main_queue(), ^{
                TBReceiverPresentationController *laterSelf = weakSelf;
                if (!laterSelf || !laterSelf.streamActive ||
                    !laterSelf->_guiSessionActive ||
                    laterSelf->_activationRequestGeneration != generation ||
                    !NSApp.isActive || laterSelf->_window.isKeyWindow) {
                    return;
                }
                receiver_diagnostic(
                    OS_LOG_TYPE_DEFAULT,
                    "window=non-key action=reclaim-deferred");
                [laterSelf requestCursorActivation];
            });
        }
    }];
    return self;
}

- (void)setStreamActive:(BOOL)streamActive {
    NSAssert(NSThread.isMainThread,
             @"stream state must be changed on the main thread");
    if (_streamActive == streamActive) {
        [self refreshLifecycleState];
        return;
    }
    _streamActive = streamActive;
    if (streamActive) {
        tb_display_lifecycle_begin_stream(&_displayLifecycle);
    } else {
        tb_display_lifecycle_end_stream(&_displayLifecycle);
    }
    if (streamActive && _guiSessionActive) {
        [self presentWithoutActivation];
        [self requestCursorActivation];
    } else {
        _activationRequestGeneration += 1;
        if (streamActive) [self scheduleStartupSessionRevalidation];
    }
    [self refreshLifecycleState];
}

- (void)requestCursorActivation {
    if (!self.streamActive || !_guiSessionActive ||
        !_displayLifecycle.source_awake) return;
    [_window makeKeyAndOrderFront:nil];
    [self refreshLifecycleState];
    const struct tb_appliance_surface_policy policy =
        tb_appliance_surface_policy_evaluate(
            self.streamActive, _guiSessionActive,
            _appForeground, _window.isKeyWindow);
    if (policy.suppress_local_cursor &&
        tb_display_lifecycle_may_hide_cursor(&_displayLifecycle) &&
        _displayPowerActive) {
        if (self.cursorActivationHandler) self.cursorActivationHandler();
        return;
    }
    if (!policy.request_activation) return;

    const NSUInteger generation = ++_activationRequestGeneration;
    if (_guiSessionActive) {
        [NSApp activateIgnoringOtherApps:YES];
    } else {
        receiver_diagnostic(
            OS_LOG_TYPE_DEFAULT,
            "appkit=activation-deferred reason=gui-session-unavailable");
    }
    __weak TBReceiverPresentationController *weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{
        TBReceiverPresentationController *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.streamActive ||
            !strongSelf->_guiSessionActive ||
            strongSelf->_activationRequestGeneration != generation ||
            NSApp.isActive) {
            return;
        }
        receiver_diagnostic(
            OS_LOG_TYPE_ERROR,
            "session=active globalCursor=hide-abandoned "
            "reason=foreground-activation-timeout handler=%s",
            strongSelf.cursorActivationHandler ? "true" : "false");
    });
}

- (void)refreshLifecycleState {
    NSAssert(NSThread.isMainThread,
             @"display lifecycle must be evaluated on the main thread");
    const BOOL publicSurfaceAvailable =
        _guiSessionActive && _appForeground && _window.isKeyWindow;
    const BOOL wantsPower = self.streamActive &&
        _displayLifecycle.source_awake && publicSurfaceAvailable;
    if (wantsPower != _displayPowerActive) {
        const BOOL transitionSucceeded = self.displayPowerGateHandler
            ? self.displayPowerGateHandler(wantsPower)
            : !wantsPower;
        _displayPowerActive = wantsPower && transitionSucceeded;
    }

    const BOOL reportedSurfaceAvailable =
        publicSurfaceAvailable &&
        (!self.streamActive || !_displayLifecycle.source_awake ||
         _displayPowerActive);
    if (reportedSurfaceAvailable != _lastReportedSurfaceAvailable) {
        _lastReportedSurfaceAvailable = reportedSurfaceAvailable;
        _reportedSurfaceEpoch++;
        if (_reportedSurfaceEpoch == 0) _reportedSurfaceEpoch = 1;
    }
    (void)tb_display_lifecycle_publish_receiver_surface(
        &_displayLifecycle,
        reportedSurfaceAvailable,
        _reportedSurfaceEpoch);
    if (self.lifecycleStateHandler) {
        self.lifecycleStateHandler(
            reportedSurfaceAvailable,
            _reportedSurfaceEpoch,
            _displayLifecycle.source_awake,
            tb_display_lifecycle_accepts_frames(&_displayLifecycle),
            _displayLifecycle.presentation_generation);
    }

    const struct tb_appliance_surface_policy appPolicy =
        tb_appliance_surface_policy_evaluate(
            self.streamActive,
            _guiSessionActive,
            _appForeground,
            _window.isKeyWindow);
    const BOOL exposeLivePixels = self.streamActive &&
        !appPolicy.privacy_blank && _displayPowerActive &&
        tb_display_lifecycle_may_expose_pixels(&_displayLifecycle);
    const BOOL exposeIdleSurface = !self.streamActive &&
        publicSurfaceAvailable;
    if (exposeLivePixels || exposeIdleSurface) {
        if (self.privacyResumeHandler) self.privacyResumeHandler();
    } else {
        if (self.privacyBlankHandler) self.privacyBlankHandler();
    }

    if (exposeLivePixels && appPolicy.suppress_local_cursor &&
        tb_display_lifecycle_may_hide_cursor(&_displayLifecycle)) {
        if (self.cursorActivationHandler) self.cursorActivationHandler();
    } else if (self.cursorDeactivationHandler) {
        self.cursorDeactivationHandler();
    }
}

- (void)scheduleStartupSessionRevalidation {
    if (_guiSessionActive || _sessionTransitionGeneration != 0) return;
    const NSUInteger retryGeneration = ++_startupSnapshotRetryGeneration;
    [self performStartupSessionRevalidation:retryGeneration remaining:20];
}

- (void)performStartupSessionRevalidation:(NSUInteger)retryGeneration
                                  remaining:(NSUInteger)remaining {
    __weak TBReceiverPresentationController *weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{
        TBReceiverPresentationController *strongSelf = weakSelf;
        if (!strongSelf ||
            strongSelf->_startupSnapshotRetryGeneration != retryGeneration ||
            strongSelf->_sessionTransitionGeneration != 0 ||
            strongSelf->_guiSessionActive) {
            return;
        }
        if (current_startup_gui_session_available()) {
            strongSelf->_guiSessionActive = YES;
            receiver_diagnostic(
                OS_LOG_TYPE_DEFAULT,
                "gui-session=startup-snapshot-recovered "
                "action=reclaim-surface");
            [strongSelf presentWithoutActivation];
            [NSApp activateIgnoringOtherApps:YES];
            if (NSApp.isActive) {
                strongSelf->_appForeground = YES;
                [strongSelf->_window makeKeyAndOrderFront:nil];
            }
            [strongSelf refreshLifecycleState];
            if (strongSelf.streamActive) {
                [strongSelf requestCursorActivation];
            }
            return;
        }
        if (remaining > 1) {
            [strongSelf performStartupSessionRevalidation:retryGeneration
                                                 remaining:remaining - 1];
        }
    });
    /* Twenty attempts are bounded to five seconds. A later wake or connect
     * starts a fresh bounded generation without polling while stably locked. */
}

- (enum tb_display_lifecycle_update)applySourceDisplayAwake:(BOOL)awake
                                                     epoch:(uint64_t)epoch
                                             receiverEpoch:(uint64_t)receiverEpoch {
    NSAssert(NSThread.isMainThread,
             @"source lifecycle must be applied on the main thread");
    const enum tb_display_lifecycle_update update =
        tb_display_lifecycle_apply_source(
            &_displayLifecycle, awake, epoch);
    const enum tb_display_lifecycle_update receiverAck =
        tb_display_lifecycle_ack_receiver_epoch(
            &_displayLifecycle, receiverEpoch);
    if (update == TB_DISPLAY_LIFECYCLE_APPLIED ||
        receiverAck == TB_DISPLAY_LIFECYCLE_APPLIED) {
        [self refreshLifecycleState];
        if (awake && self.streamActive && _guiSessionActive) {
            [self presentWithoutActivation];
            [self requestCursorActivation];
        }
    }
    return update;
}

- (BOOL)markFreshFramePresentedForGeneration:(uint64_t)generation {
    NSAssert(NSThread.isMainThread,
             @"fresh-frame lifecycle must be applied on the main thread");
    if (tb_display_lifecycle_note_presented_frame(
            &_displayLifecycle, generation)) {
        [self refreshLifecycleState];
        return YES;
    }
    return NO;
}

- (BOOL)admitLegacyFrameForGeneration:(uint64_t *)generation {
    NSAssert(NSThread.isMainThread,
             @"legacy frame admission must be checked on the main thread");
    if (!tb_display_lifecycle_assume_legacy_peer(&_displayLifecycle)) {
        return NO;
    }
    [self refreshLifecycleState];
    if (generation) {
        *generation = _displayLifecycle.presentation_generation;
    }
    return tb_display_lifecycle_accepts_frames(&_displayLifecycle);
}

- (void)reapplyCursorShield {
    if (![_window.contentView isKindOfClass:TBCursorShieldView.class]) return;
    TBCursorShieldView *surface =
        (TBCursorShieldView *)_window.contentView;
    [_window invalidateCursorRectsForView:surface];
    [surface reapplyCursorPolicy];
}

- (void)presentWithoutActivation {
    [_window orderFrontRegardless];
    [_window displayIfNeeded];
    [_window.contentView displayIfNeeded];
    [self reapplyCursorShield];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    const BOOL regularPolicySet =
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    receiver_diagnostic(
        NSApp.activationPolicy == NSApplicationActivationPolicyRegular
            ? OS_LOG_TYPE_DEFAULT
            : OS_LOG_TYPE_ERROR,
        "appkit=did-finish-launching requestedPolicy=regular "
        "accepted=%s effectivePolicy=%ld",
        regularPolicySet ? "true" : "false",
        (long)NSApp.activationPolicy);
    if (NSApp.activationPolicy != NSApplicationActivationPolicyRegular) {
        receiver_diagnostic(
            OS_LOG_TYPE_FAULT,
            "appkit=launch-contract-failed expectedPolicy=regular "
            "effectivePolicy=%ld admission=closed",
            (long)NSApp.activationPolicy);
        (void)kill(getpid(), SIGTERM);
        return;
    }
    /* Activation is asynchronous. Make the window key only from the matching
     * delegate callback instead of racing AppKit during launch-agent startup. */
    if (_sessionTransitionGeneration == 0) {
        _guiSessionActive = current_startup_gui_session_available();
    }
    if (_guiSessionActive) {
        [NSApp activateIgnoringOtherApps:YES];
    } else {
        receiver_diagnostic(
            OS_LOG_TYPE_DEFAULT,
            "appkit=activation-deferred reason=gui-session-unavailable");
        [self scheduleStartupSessionRevalidation];
    }
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    if (_sessionTransitionGeneration == 0) {
        _guiSessionActive = current_startup_gui_session_available();
    }
    if (!_guiSessionActive) {
        _appForeground = NO;
        [self refreshLifecycleState];
        receiver_diagnostic(
            OS_LOG_TYPE_DEFAULT,
            "appkit=became-active surface=withheld reason=locked-snapshot");
        [self scheduleStartupSessionRevalidation];
        return;
    }
    _appForeground = YES;
    [self presentWithoutActivation];
    [_window makeKeyAndOrderFront:nil];
    _activationRequestGeneration += 1;
    [self reapplyCursorShield];
    [self refreshLifecycleState];
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    (void)notification;
    _appForeground = NO;
    _activationRequestGeneration += 1;
    [self refreshLifecycleState];
    receiver_diagnostic(
        OS_LOG_TYPE_DEFAULT,
        "appkit=will-resign-active stream=%s cursor=released surface=blank",
        self.streamActive ? "true" : "false");
    if (self.streamActive && _guiSessionActive) {
        const NSUInteger generation = _activationRequestGeneration;
        __weak TBReceiverPresentationController *weakSelf = self;
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{
            TBReceiverPresentationController *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.streamActive ||
                !strongSelf->_guiSessionActive ||
                strongSelf->_activationRequestGeneration != generation ||
                NSApp.isActive) {
                return;
            }
            [strongSelf requestCursorActivation];
        });
    }
}

- (void)invalidate {
    self.streamActive = NO;
    self.cursorActivationHandler = nil;
    self.cursorDeactivationHandler = nil;
    self.privacyBlankHandler = nil;
    self.privacyResumeHandler = nil;
    self.displayPowerGateHandler = nil;
    self.lifecycleStateHandler = nil;
    if (_screensDidWakeObserver) {
        [NSWorkspace.sharedWorkspace.notificationCenter
            removeObserver:_screensDidWakeObserver];
        _screensDidWakeObserver = nil;
    }
    if (_sessionDidBecomeActiveObserver) {
        [NSWorkspace.sharedWorkspace.notificationCenter
            removeObserver:_sessionDidBecomeActiveObserver];
        _sessionDidBecomeActiveObserver = nil;
    }
    if (_sessionDidResignActiveObserver) {
        [NSWorkspace.sharedWorkspace.notificationCenter
            removeObserver:_sessionDidResignActiveObserver];
        _sessionDidResignActiveObserver = nil;
    }
    if (_windowDidBecomeKeyObserver) {
        [NSNotificationCenter.defaultCenter
            removeObserver:_windowDidBecomeKeyObserver];
        _windowDidBecomeKeyObserver = nil;
    }
    if (_windowDidResignKeyObserver) {
        [NSNotificationCenter.defaultCenter
            removeObserver:_windowDidResignKeyObserver];
        _windowDidResignKeyObserver = nil;
    }
}

@end

static void fail(const char *operation) {
    fprintf(stderr, "TB_PROTOCOL_METAL error=%s errno=%d message=%s\n",
            operation, errno, strerror(errno));
    exit(1);
}

static uint32_t load_be32(const uint8_t bytes[4]) {
    return ((uint32_t)bytes[0] << 24) |
           ((uint32_t)bytes[1] << 16) |
           ((uint32_t)bytes[2] << 8) |
           (uint32_t)bytes[3];
}

static void store_be32(uint8_t bytes[4], uint32_t value) {
    bytes[0] = (uint8_t)(value >> 24);
    bytes[1] = (uint8_t)(value >> 16);
    bytes[2] = (uint8_t)(value >> 8);
    bytes[3] = (uint8_t)value;
}

static bool read_exact(int fd, void *buffer, size_t length) {
    uint8_t *cursor = (uint8_t *)buffer;
    while (length > 0) {
        ssize_t received = recv(fd, cursor, length, 0);
        if (received < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (received == 0) {
            // A prior interrupted recv may have left EINTR in errno. Callers
            // use errno==0 to distinguish an orderly EOF from a socket error.
            errno = 0;
            return false;
        }
        cursor += (size_t)received;
        length -= (size_t)received;
    }
    return true;
}

enum tb_wire_packet_read_result {
    TB_WIRE_PACKET_READ_OK = 0,
    TB_WIRE_PACKET_READ_LENGTH_FAILED,
    TB_WIRE_PACKET_READ_INVALID_LENGTH,
    TB_WIRE_PACKET_READ_TYPE_FAILED,
    TB_WIRE_PACKET_READ_PAYLOAD_FAILED
};

struct tb_wire_packet {
    enum tb_wire_packet_read_result result;
    uint32_t packet_length;
    uint8_t packet_type;
    size_t payload_length;
    int error_number;
    double payload_started;
    double completed;
};

/* Read one complete framed packet into caller-owned storage. Keeping the
 * framing state in a value object lets the optional second receive slot run on
 * a dedicated serial queue while the transport worker submits the preceding
 * immutable slot to Metal. The caller must not reuse `payload` until this
 * function has returned. */
static struct tb_wire_packet read_wire_packet(int fd, uint8_t *payload) {
    struct tb_wire_packet packet;
    memset(&packet, 0, sizeof(packet));

    uint8_t lengthBytes[4];
    errno = 0;
    if (!read_exact(fd, lengthBytes, sizeof(lengthBytes))) {
        packet.result = TB_WIRE_PACKET_READ_LENGTH_FAILED;
        packet.error_number = errno;
        return packet;
    }

    packet.packet_length = load_be32(lengthBytes);
    if (packet.packet_length < 1 ||
        packet.packet_length > TB_MAX_PACKET_LENGTH) {
        packet.result = TB_WIRE_PACKET_READ_INVALID_LENGTH;
        return packet;
    }

    errno = 0;
    if (!read_exact(fd, &packet.packet_type, 1)) {
        packet.result = TB_WIRE_PACKET_READ_TYPE_FAILED;
        packet.error_number = errno;
        return packet;
    }

    packet.payload_length = (size_t)packet.packet_length - 1;
    packet.payload_started = CACurrentMediaTime();
    errno = 0;
    if (packet.payload_length > 0 &&
        !read_exact(fd, payload, packet.payload_length)) {
        packet.result = TB_WIRE_PACKET_READ_PAYLOAD_FAILED;
        packet.error_number = errno;
        return packet;
    }
    packet.completed = CACurrentMediaTime();
    packet.result = TB_WIRE_PACKET_READ_OK;
    return packet;
}

static bool environment_flag_enabled(const char *name) {
    const char *value = getenv(name);
    return value &&
        (strcmp(value, "1") == 0 ||
         strcasecmp(value, "true") == 0 ||
         strcasecmp(value, "yes") == 0);
}

static bool read_exact_before(int fd,
                              void *buffer,
                              size_t length,
                              CFTimeInterval deadline) {
    uint8_t *cursor = (uint8_t *)buffer;
    while (length > 0) {
        const CFTimeInterval remaining = deadline - CACurrentMediaTime();
        if (remaining <= 0.0) {
            errno = ETIMEDOUT;
            return false;
        }
        int waitMilliseconds = (int)ceil(remaining * 1000.0);
        if (waitMilliseconds < 1) waitMilliseconds = 1;
        struct pollfd descriptor = {
            .fd = fd,
            .events = POLLIN,
            .revents = 0
        };
        int ready;
        do {
            ready = poll(&descriptor, 1, waitMilliseconds);
        } while (ready < 0 && errno == EINTR);
        if (ready == 0) {
            errno = ETIMEDOUT;
            return false;
        }
        if (ready < 0) return false;

        ssize_t received = recv(fd, cursor, length, 0);
        if (received < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (received == 0) return false;
        cursor += (size_t)received;
        length -= (size_t)received;
    }
    return true;
}

static bool discard_exact(int fd, size_t length) {
    /* Match the sender's normal path-probe chunk so a 17+ Gbit/s link is not
     * artificially capped by thousands of tiny receive syscalls. */
    uint8_t scratch[256 * 1024];
    while (length > 0) {
        const size_t chunk = length < sizeof(scratch)
            ? length : sizeof(scratch);
        if (!read_exact(fd, scratch, chunk)) return false;
        length -= chunk;
    }
    return true;
}

static bool discard_exact_before(int fd,
                                 size_t length,
                                 CFTimeInterval deadline) {
    uint8_t scratch[256 * 1024];
    while (length > 0) {
        const size_t chunk = length < sizeof(scratch)
            ? length : sizeof(scratch);
        if (!read_exact_before(fd, scratch, chunk, deadline)) return false;
        length -= chunk;
    }
    return true;
}

static bool write_exact(int fd, const void *buffer, size_t length) {
    const uint8_t *cursor = (const uint8_t *)buffer;
    while (length > 0) {
        ssize_t written = send(fd, cursor, length, 0);
        if (written < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (written == 0) return false;
        cursor += (size_t)written;
        length -= (size_t)written;
    }
    return true;
}

static bool send_display_profile(int fd, bool supportsDPCM) {
    char json[768];
    const int jsonCharacters = snprintf(
        json, sizeof(json),
        "{\"receiverName\":\"2017 iMac Raw Metal\","
        "\"panelWidth\":5120,\"panelHeight\":2880,"
        "\"modeWidth\":2560,\"modeHeight\":1440,"
        "\"refreshRate\":60,\"hiDPI\":true,"
        "\"captureWidth\":5120,\"captureHeight\":2880,"
        "\"supportsHEVCDecode\":false,\"supportsRawNV12\":true,"
        "\"supportsDPCM\":%s,"
        "\"supportsDisplayLifecycle\":true,"
        "\"inputMonitoringTrusted\":false,"
        "\"accessibilityTrusted\":false,"
        "\"supportsNightShift\":false,\"supportsTrueTone\":false}",
        supportsDPCM ? "true" : "false");
    if (jsonCharacters < 0 || (size_t)jsonCharacters >= sizeof(json)) return false;
    const size_t jsonLength = (size_t)jsonCharacters;
    uint8_t header[5];
    store_be32(header, (uint32_t)(1 + jsonLength));
    header[4] = TB_PACKET_DISPLAY_PROFILE;
    return write_exact(fd, header, sizeof(header)) &&
           write_exact(fd, json, jsonLength);
}

static bool send_receiver_surface_state(int fd,
                                        bool available,
                                        uint64_t epoch) {
    char json[96];
    const int jsonCharacters = snprintf(
        json, sizeof(json),
        "{\"available\":%s,\"epoch\":%llu}",
        available ? "true" : "false",
        (unsigned long long)epoch);
    if (jsonCharacters < 0 || (size_t)jsonCharacters >= sizeof(json)) {
        return false;
    }
    const size_t jsonLength = (size_t)jsonCharacters;
    uint8_t header[5];
    store_be32(header, (uint32_t)(1 + jsonLength));
    header[4] = TB_PACKET_RECEIVER_SURFACE_STATE;
    return write_exact(fd, header, sizeof(header)) &&
        write_exact(fd, json, jsonLength);
}

static int compare_double(const void *left, const void *right) {
    double a = *(const double *)left;
    double b = *(const double *)right;
    return (a > b) - (a < b);
}

static double percentile(double *values, uint32_t count, unsigned wanted) {
    if (count == 0) return 0.0;
    qsort(values, count, sizeof(*values), compare_double);
    uint64_t rank = ((uint64_t)count * wanted + 99) / 100;
    if (rank == 0) rank = 1;
    if (rank > count) rank = count;
    return values[rank - 1];
}

static double renderer_histogram_percentile(
    const uint64_t histogram[TB_NATIVE_METAL_TIMING_BUCKETS],
    unsigned wanted) {
    uint64_t count = 0;
    for (size_t index = 0; index < TB_NATIVE_METAL_TIMING_BUCKETS; index++) {
        count += histogram[index];
    }
    if (count == 0) return 0.0;
    uint64_t rank = (count * wanted + 99) / 100;
    uint64_t cumulative = 0;
    for (size_t index = 0; index < TB_NATIVE_METAL_TIMING_BUCKETS; index++) {
        cumulative += histogram[index];
        if (cumulative >= rank) {
            return (double)(index + 1) * TB_NATIVE_METAL_TIMING_BUCKET_MS;
        }
    }
    return TB_NATIVE_METAL_TIMING_BUCKETS * TB_NATIVE_METAL_TIMING_BUCKET_MS;
}

static int make_listener(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) fail("socket");
    int reuse = 1;
    (void)setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    int requested = 4 * 1024 * 1024;
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &requested, sizeof(requested));
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) fail("bind");
    if (listen(fd, 1) != 0) fail("listen");
    return fd;
}

static NSScreen *native_builtin_5k_screen(CGDirectDisplayID *selectedDisplayID) {
    if (selectedDisplayID) *selectedDisplayID = kCGNullDirectDisplay;
    for (NSScreen *candidate in NSScreen.screens) {
        NSNumber *screenNumber =
            candidate.deviceDescription[@"NSScreenNumber"];
        const CGDirectDisplayID displayID = screenNumber
            ? (CGDirectDisplayID)screenNumber.unsignedIntValue
            : kCGNullDirectDisplay;
        CGDisplayModeRef mode = displayID != kCGNullDirectDisplay
            ? CGDisplayCopyDisplayMode(displayID)
            : NULL;
        const size_t pixelWidth = mode ? CGDisplayModeGetPixelWidth(mode) : 0;
        const size_t pixelHeight = mode ? CGDisplayModeGetPixelHeight(mode) : 0;
        const bool accepted = displayID != kCGNullDirectDisplay &&
            CGDisplayIsBuiltin(displayID) &&
            CGDisplayIsActive(displayID) &&
            pixelWidth == 5120 && pixelHeight == 2880 &&
            candidate.backingScaleFactor == 2.0;
        fprintf(stderr,
                "TB_PROTOCOL_METAL panelCandidate=%s displayID=%u builtin=%s "
                "active=%s modePixels=%zux%zu scale=%.2f "
                "frame=%.0f,%.0f %.0fx%.0f\n",
                accepted ? "selected" : "rejected",
                (unsigned int)displayID,
                displayID != kCGNullDirectDisplay &&
                    CGDisplayIsBuiltin(displayID) ? "true" : "false",
                displayID != kCGNullDirectDisplay &&
                    CGDisplayIsActive(displayID) ? "true" : "false",
                pixelWidth, pixelHeight,
                candidate.backingScaleFactor,
                candidate.frame.origin.x, candidate.frame.origin.y,
                candidate.frame.size.width, candidate.frame.size.height);
        if (mode) CGDisplayModeRelease(mode);
        if (accepted) {
            if (selectedDisplayID) *selectedDisplayID = displayID;
            return candidate;
        }
    }
    return nil;
}

static bool copy_thunderbolt_ipv4(char output[INET_ADDRSTRLEN]) {
    output[0] = '\0';
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) return false;

    bool found = false;
    for (const struct ifaddrs *entry = interfaces;
         entry != NULL;
         entry = entry->ifa_next) {
        if (!entry->ifa_addr || entry->ifa_addr->sa_family != AF_INET ||
            !(entry->ifa_flags & IFF_UP) ||
            (entry->ifa_flags & IFF_LOOPBACK) ||
            strcmp(entry->ifa_name, "bridge0") != 0) {
            continue;
        }

        const struct sockaddr_in *address =
            (const struct sockaddr_in *)entry->ifa_addr;
        char candidate[INET_ADDRSTRLEN];
        if (!inet_ntop(AF_INET, &address->sin_addr,
                       candidate, sizeof(candidate))) {
            continue;
        }

        /* Only bridge0's self-assigned peer link is Thunderbolt Bridge. A
         * non-bridge 169.254/16 address may be USB-NCM (or an unrelated
         * self-assigned interface) and must never be published as tbIP. */
        if (strncmp(candidate, "169.254.", 8) == 0) {
            snprintf(output, INET_ADDRSTRLEN, "%s", candidate);
            found = true;
            break;
        }
    }
    freeifaddrs(interfaces);
    return found;
}

static bool peer_arrived_via_bridge0_link_local(int peer) {
    struct sockaddr_in localAddress;
    memset(&localAddress, 0, sizeof(localAddress));
    socklen_t localLength = sizeof(localAddress);
    if (getsockname(peer, (struct sockaddr *)&localAddress, &localLength) != 0 ||
        localLength < sizeof(localAddress) ||
        localAddress.sin_family != AF_INET) {
        return false;
    }

    const uint32_t hostAddress = ntohl(localAddress.sin_addr.s_addr);
    if (!tb_pre_session_is_ipv4_link_local(hostAddress)) return false;

    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) return false;
    bool matched = false;
    for (const struct ifaddrs *entry = interfaces;
         entry != NULL;
         entry = entry->ifa_next) {
        if (!entry->ifa_addr || entry->ifa_addr->sa_family != AF_INET ||
            !(entry->ifa_flags & IFF_UP) ||
            (entry->ifa_flags & IFF_LOOPBACK) ||
            strcmp(entry->ifa_name, "bridge0") != 0) {
            continue;
        }
        const struct sockaddr_in *bridgeAddress =
            (const struct sockaddr_in *)entry->ifa_addr;
        if (bridgeAddress->sin_addr.s_addr == localAddress.sin_addr.s_addr) {
            matched = true;
            break;
        }
    }
    freeifaddrs(interfaces);
    return matched;
}

@interface TBBonjourPublisher : NSObject {
@private
    uint16_t _port;
    BOOL _supportsDPCM;
    BOOL _invalidated;
    char _lastThunderboltIP[INET_ADDRSTRLEN];
    dispatch_queue_t _queue;
    dispatch_source_t _refreshTimer;
    DNSServiceRef _service;
    uint64_t _serviceGeneration;
}
- (instancetype)initWithPort:(uint16_t)port supportsDPCM:(BOOL)supportsDPCM;
- (void)invalidate;
@end

@interface TBBonjourPublisher ()
- (void)invalidateLocked;
- (void)publishLocked;
- (void)refreshAddressLocked;
- (void)registrationCompleted:(DNSServiceRef)service
                         error:(DNSServiceErrorType)error
                          name:(const char *)name;
@end

static const void *TBBonjourQueueKey = &TBBonjourQueueKey;

static void on_bonjour_register(DNSServiceRef service,
                                DNSServiceFlags flags,
                                DNSServiceErrorType error,
                                const char *name,
                                const char *type,
                                const char *domain,
                                void *context) {
    (void)flags;
    (void)type;
    (void)domain;
    TBBonjourPublisher *publisher =
        (__bridge TBBonjourPublisher *)context;
    [publisher registrationCompleted:service error:error name:name];
}

@implementation TBBonjourPublisher

- (instancetype)initWithPort:(uint16_t)port supportsDPCM:(BOOL)supportsDPCM {
    self = [super init];
    if (!self) return nil;
    _port = port;
    _supportsDPCM = supportsDPCM;
    _lastThunderboltIP[0] = '\0';
    _queue = dispatch_queue_create(
        "com.targetbridge.receiver5k.bonjour", DISPATCH_QUEUE_SERIAL);
    if (!_queue) return nil;
    dispatch_queue_set_specific(
        _queue, TBBonjourQueueKey, (void *)TBBonjourQueueKey, NULL);
    dispatch_sync(_queue, ^{
        [self publishLocked];
        self->_refreshTimer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_queue);
        if (self->_refreshTimer) {
            dispatch_source_set_timer(
                self->_refreshTimer,
                dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                2 * NSEC_PER_SEC,
                NSEC_PER_SEC / 4);
            __weak TBBonjourPublisher *weakSelf = self;
            dispatch_source_set_event_handler(self->_refreshTimer, ^{
                [weakSelf refreshAddressLocked];
            });
            dispatch_resume(self->_refreshTimer);
        }
    });
    return self;
}

- (void)dealloc {
    [self invalidate];
}

- (void)invalidateLocked {
    if (_invalidated) return;
    _invalidated = YES;
    if (_refreshTimer) {
        dispatch_source_cancel(_refreshTimer);
        _refreshTimer = nil;
    }
    if (_service) {
        DNSServiceRefDeallocate(_service);
        _service = NULL;
    }
    _serviceGeneration++;
}

- (void)invalidate {
    if (!_queue) return;
    if (dispatch_get_specific(TBBonjourQueueKey)) {
        [self invalidateLocked];
    } else {
        dispatch_sync(_queue, ^{
            [self invalidateLocked];
        });
    }
}

- (void)refreshAddressLocked {
    if (_invalidated) return;
    char thunderboltIP[INET_ADDRSTRLEN] = {0};
    (void)copy_thunderbolt_ipv4(thunderboltIP);
    /* A registration callback can fail after DNSServiceRegister itself
     * succeeded. In that case the bridge address may be unchanged, so address
     * comparison alone would leave discovery dead until the next cable event.
     * The bounded two-second timer also repairs a missing service in place. */
    if (!_service || strcmp(thunderboltIP, _lastThunderboltIP) != 0) {
        [self publishLocked];
    }
}

- (void)publishLocked {
    if (_invalidated) return;
    _serviceGeneration++;
    if (_service) {
        DNSServiceRefDeallocate(_service);
        _service = NULL;
    }

    char thunderboltIP[INET_ADDRSTRLEN] = {0};
    (void)copy_thunderbolt_ipv4(thunderboltIP);
    snprintf(_lastThunderboltIP, sizeof(_lastThunderboltIP),
             "%s", thunderboltIP);

    TXTRecordRef txt;
    TXTRecordCreate(&txt, 0, NULL);
    static const char receiverName[] = "iMac 5K Display Appliance";
    static const char panelName[] = "2017 27-inch Retina 5K iMac";
    static const char panelWidth[] = "5120";
    static const char panelHeight[] = "2880";
    static const char version[] = "0.2";
    TXTRecordSetValue(&txt, "name", sizeof(receiverName) - 1, receiverName);
    TXTRecordSetValue(&txt, "panel", sizeof(panelName) - 1, panelName);
    TXTRecordSetValue(&txt, "panelWidth", sizeof(panelWidth) - 1, panelWidth);
    TXTRecordSetValue(&txt, "panelHeight", sizeof(panelHeight) - 1, panelHeight);
    TXTRecordSetValue(&txt, "version", sizeof(version) - 1, version);
    TXTRecordSetValue(&txt, "supportsHEVCDecode", 1, "0");
    TXTRecordSetValue(&txt, "supportsRawNV12", 1, "1");
    TXTRecordSetValue(&txt, "supportsDPCM", 1, _supportsDPCM ? "1" : "0");
    if (thunderboltIP[0] != '\0') {
        const uint8_t length = (uint8_t)strlen(thunderboltIP);
        TXTRecordSetValue(&txt, "ip", length, thunderboltIP);
        TXTRecordSetValue(&txt, "tbIP", length, thunderboltIP);
    }

    DNSServiceRef service = NULL;
    DNSServiceErrorType result = DNSServiceRegister(
        &service,
        0,
        0,
        receiverName,
        "_targetbridge._tcp",
        "local.",
        NULL,
        htons(_port),
        TXTRecordGetLength(&txt),
        TXTRecordGetBytesPtr(&txt),
        on_bonjour_register,
        (__bridge void *)self);
    TXTRecordDeallocate(&txt);
    if (result == kDNSServiceErr_NoError) {
        result = DNSServiceSetDispatchQueue(service, _queue);
    }
    if (result != kDNSServiceErr_NoError) {
        fprintf(stderr, "TB_PROTOCOL_METAL bonjour=failed error=%d\n", (int)result);
        if (service) DNSServiceRefDeallocate(service);
        return;
    }
    _service = service;
}

- (void)registrationCompleted:(DNSServiceRef)service
                         error:(DNSServiceErrorType)error
                          name:(const char *)name {
    fprintf(stderr, "TB_PROTOCOL_METAL bonjour=%s name=%s error=%d tbIP=%s dpcm=%s\n",
            error == kDNSServiceErr_NoError ? "published" : "failed",
            name ? name : "iMac 5K Display Appliance",
            (int)error,
            _lastThunderboltIP[0] ? _lastThunderboltIP : "none",
            _supportsDPCM ? "true" : "false");
    if (error != kDNSServiceErr_NoError && service == _service) {
        const uint64_t failedGeneration = _serviceGeneration;
        dispatch_async(_queue, ^{
            if (self->_service == service &&
                self->_serviceGeneration == failedGeneration) {
                DNSServiceRefDeallocate(self->_service);
                self->_service = NULL;
                self->_serviceGeneration++;
            }
        });
    }
}

@end

static bool physical_panel_accepts_dpcm(NSWindow *window,
                                        CGDirectDisplayID expectedDisplayID,
                                        int sourceWidth,
                                        int sourceHeight) {
    NSScreen *hostingScreen = window.screen;
    NSView *contentView = window.contentView;
    NSNumber *screenNumber =
        hostingScreen.deviceDescription[@"NSScreenNumber"];
    const CGDirectDisplayID displayID = screenNumber
        ? (CGDirectDisplayID)screenNumber.unsignedIntValue
        : kCGNullDirectDisplay;
    CGDisplayModeRef mode = displayID != kCGNullDirectDisplay
        ? CGDisplayCopyDisplayMode(displayID)
        : NULL;

    const NSSize contentPoints = contentView.bounds.size;
    const NSSize screenPoints = hostingScreen.frame.size;
    const NSRect windowFrame = window.frame;
    const NSRect screenFrame = hostingScreen.frame;
    const NSRect backingBounds = contentView
        ? [contentView convertRectToBacking:contentView.bounds]
        : NSZeroRect;
    const size_t modePixelWidth = mode ? CGDisplayModeGetPixelWidth(mode) : 0;
    const size_t modePixelHeight = mode ? CGDisplayModeGetPixelHeight(mode) : 0;
    const CGFloat scale = hostingScreen ? hostingScreen.backingScaleFactor : 0.0;
    const bool exactWindowFrame = hostingScreen &&
        NSEqualRects(windowFrame, screenFrame);
    const bool fullScreenPoints = hostingScreen && contentView &&
        NSEqualSizes(contentPoints, screenPoints);
    const bool builtinActive = displayID != kCGNullDirectDisplay &&
        displayID == expectedDisplayID &&
        CGDisplayIsBuiltin(displayID) && CGDisplayIsActive(displayID);
    const bool exactScale = scale == 2.0;
    const bool exactMode =
        modePixelWidth == 5120 && modePixelHeight == 2880;
    const bool exactDrawable =
        (size_t)llround(backingBounds.size.width) == 5120 &&
        (size_t)llround(backingBounds.size.height) == 2880;
    const bool exactSource = sourceWidth == 5120 && sourceHeight == 2880;
    const bool accepted = builtinActive && exactWindowFrame &&
        fullScreenPoints && exactScale && exactMode && exactDrawable &&
        exactSource;

    fprintf(stderr,
            "TB_PROTOCOL_METAL physicalGate=%s displayID=%u "
            "builtinActive=%s windowFrame=%.0f,%.0f %.0fx%.0f "
            "screenFrame=%.0f,%.0f %.0fx%.0f "
            "contentPoints=%.0fx%.0f screenPoints=%.0fx%.0f scale=%.2f "
            "modePixels=%zux%zu drawable=%zux%zu source=%dx%d\n",
            accepted ? "accepted" : "rejected",
            (unsigned int)displayID,
            builtinActive ? "true" : "false",
            windowFrame.origin.x, windowFrame.origin.y,
            windowFrame.size.width, windowFrame.size.height,
            screenFrame.origin.x, screenFrame.origin.y,
            screenFrame.size.width, screenFrame.size.height,
            contentPoints.width, contentPoints.height,
            screenPoints.width, screenPoints.height,
            scale,
            modePixelWidth, modePixelHeight,
            (size_t)llround(backingBounds.size.width),
            (size_t)llround(backingBounds.size.height),
            sourceWidth, sourceHeight);
    if (mode) CGDisplayModeRelease(mode);
    if (accepted) {
        receiver_diagnostic(
            OS_LOG_TYPE_DEFAULT,
            "physical gate accepted display=%u raster=5120x2880 scale=2",
            (unsigned int)displayID);
    }
    return accepted;
}

static bool write_luma_snapshot(const char *path,
                                const struct tb_raw_nv12_view *frame) {
    if (!path || !frame) return false;
    const uint32_t step = 8;
    const uint32_t outputWidth = frame->width / step;
    const uint32_t outputHeight = frame->height / step;
    FILE *file = fopen(path, "wb");
    if (!file) return false;
    if (fprintf(file, "P5\n%u %u\n255\n", outputWidth, outputHeight) < 0) {
        fclose(file);
        return false;
    }
    bool ok = true;
    for (uint32_t y = 0; y < frame->height && ok; y += step) {
        const uint8_t *row = frame->y + (size_t)y * frame->y_stride;
        for (uint32_t x = 0; x < frame->width; x += step) {
            const int limited = row[x];
            const int stretched = limited <= 16
                ? 0
                : limited >= 235 ? 255 : (limited - 16) * 255 / 219;
            const uint8_t pixel = (uint8_t)stretched;
            if (fwrite(&pixel, 1, 1, file) != 1) {
                ok = false;
                break;
            }
        }
    }
    if (fclose(file) != 0) ok = false;
    return ok;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // A normal Finder/LaunchServices app launch is the persistent appliance
        // workflow. Passing a numeric frame count retains the bounded benchmark
        // used by the hardware verification suite.
        const bool serveForever = argc == 1 ||
            (argc > 1 && strcmp(argv[1], "--serve") == 0);
        const uint32_t expectedFrames = serveForever
            ? UINT32_MAX
            : (uint32_t)(argc > 1 ? atoi(argv[1]) : 600);
        const int portValue = serveForever
            ? (argc > 2 ? atoi(argv[2]) : 54321)
            : (argc > 2 ? atoi(argv[2]) : 54321);
        const char *snapshotPath = serveForever
            ? NULL
            : (argc > 3 ? argv[3] : NULL);
        const bool invalidArguments = serveForever
            ? argc > 3
            : (argc > 4 || expectedFrames < 1 || expectedFrames > 36000);
        if (invalidArguments || portValue <= 0 || portValue > 65535) {
            fprintf(stderr,
                    "usage: %s [frames=600] [port=54321] [luma-snapshot.pgm]\n"
                    "       %s --serve [port=54321]\n",
                    argv[0],
                    argv[0]);
            return 64;
        }

        [NSApplication sharedApplication];
        BOOL activationPolicySet =
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        fprintf(stderr,
                "TB_PROTOCOL_METAL activationPolicy=%ld requestedPolicySet=%s\n",
                (long)NSApp.activationPolicy,
                activationPolicySet ? "true" : "false");
        receiver_diagnostic(
            NSApp.activationPolicy == NSApplicationActivationPolicyRegular
                ? OS_LOG_TYPE_DEFAULT
                : OS_LOG_TYPE_ERROR,
            "appkit=pre-run requestedPolicy=regular accepted=%s "
            "effectivePolicy=%ld",
            activationPolicySet ? "true" : "false",
            (long)NSApp.activationPolicy);
        // This executable supplies its own main() instead of NSApplicationMain.
        // Build the principal menu before entering NSApplication's event loop;
        // -run completes the AppKit launch lifecycle exactly once.

        // The display surface is intentionally quiet, but this is still a Mac
        // application rather than a passive input. A minimal native app menu
        // keeps About and Quit discoverable when the pointer reveals the menu
        // bar, without leaving controls over a live stream.
        NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];
        NSMenuItem *appMenuItem = [[NSMenuItem alloc]
            initWithTitle:@"iMac 5K Display Appliance"
                   action:nil
            keyEquivalent:@""];
        NSMenu *appMenu = [[NSMenu alloc]
            initWithTitle:@"iMac 5K Display Appliance"];
        static TBReceiverMenuController *menuController;
        menuController = [[TBReceiverMenuController alloc] init];
        NSMenuItem *aboutItem = [[NSMenuItem alloc]
            initWithTitle:@"About iMac 5K Display Appliance"
                   action:@selector(orderFrontStandardAboutPanel:)
            keyEquivalent:@""];
        aboutItem.target = NSApp;
        [appMenu addItem:aboutItem];
        [appMenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *quitItem = [[NSMenuItem alloc]
            initWithTitle:@"Quit iMac 5K Display Appliance"
                   action:@selector(requestGracefulQuit:)
            keyEquivalent:@"q"];
        quitItem.target = menuController;
        [appMenu addItem:quitItem];
        appMenuItem.submenu = appMenu;
        [mainMenu addItem:appMenuItem];
        NSApp.mainMenu = mainMenu;

        NSApp.presentationOptions =
            NSApplicationPresentationHideDock |
            NSApplicationPresentationHideMenuBar;

        /* Acquire the appliance-wide system assertion before display
         * discovery. If launchd restarts us while the panel is asleep, waking
         * and polling first avoids an EX_UNAVAILABLE restart loop in which no
         * process remains alive long enough to keep the iMac reachable. */
        __block struct tb_power_lifecycle powerLifecycle;
        if (tb_power_lifecycle_start(&powerLifecycle) != 0) {
            tb_power_lifecycle_stop(&powerLifecycle);
            fprintf(stderr,
                    "TB_PROTOCOL_METAL result=failed "
                    "reason=startup-power-lifecycle\n");
            return 72;
        }
        CGDirectDisplayID selectedDisplayID = kCGNullDirectDisplay;
        NSScreen *screen = nil;
        unsigned int panelWakeAttempt = 0;
        while (!screen) {
        @autoreleasepool {
            panelWakeAttempt++;
            const BOOL startupSessionAvailable =
                current_startup_gui_session_available();
            const int wakeResult = startupSessionAvailable
                ? tb_power_lifecycle_begin_session(&powerLifecycle)
                : EACCES;
            if (wakeResult == 0) {
                const CFTimeInterval panelWakeDeadline =
                    CACurrentMediaTime() + 8.0;
                do {
                    screen = native_builtin_5k_screen(&selectedDisplayID);
                    if (screen) break;
                    [[NSRunLoop currentRunLoop]
                        runUntilDate:[NSDate
                            dateWithTimeIntervalSinceNow:0.1]];
                } while (CACurrentMediaTime() < panelWakeDeadline);
            }

            /* Between attempts, retain only the inexpensive system assertion.
             * The display follows its normal sleep preference until the next
             * bounded wake attempt or an ordinary local wake notification. */
            tb_power_lifecycle_end_session(&powerLifecycle);
            if (screen) break;

            if (!startupSessionAvailable &&
                (panelWakeAttempt == 1 || panelWakeAttempt % 120 == 0)) {
                receiver_diagnostic(
                    OS_LOG_TYPE_DEFAULT,
                    "startup=panel-wake-deferred "
                    "reason=gui-session-unavailable attempt=%u",
                    panelWakeAttempt);
            }

            if (!serveForever) {
                receiver_diagnostic(
                    OS_LOG_TYPE_ERROR,
                    "startup=panel-unavailable mode=bounded attempt=%u "
                    "wakeResult=%d deadlineSeconds=8",
                    panelWakeAttempt,
                    wakeResult);
                tb_power_lifecycle_stop(&powerLifecycle);
                fprintf(stderr,
                        "TB_PROTOCOL_METAL result=failed "
                        "reason=no-active-builtin-native-5k-panel\n");
                return 69;
            }

            const double backoffSeconds = MIN(
                30.0,
                2.0 * (double)MIN(panelWakeAttempt, 15u));
            if (startupSessionAvailable ||
                panelWakeAttempt == 1 || panelWakeAttempt % 120 == 0) {
                receiver_diagnostic(
                    startupSessionAvailable
                        ? (wakeResult == 0
                            ? OS_LOG_TYPE_ERROR
                            : OS_LOG_TYPE_FAULT)
                        : OS_LOG_TYPE_DEFAULT,
                    "startup=panel-wait attempt=%u wakeResult=%d "
                    "fastPathSeconds=8 backoffSeconds=%.0f",
                    panelWakeAttempt,
                    wakeResult,
                    backoffSeconds);
            }
            const CFTimeInterval retryDeadline =
                CACurrentMediaTime() + backoffSeconds;
            do {
                [[NSRunLoop currentRunLoop]
                    runUntilDate:[NSDate
                        dateWithTimeIntervalSinceNow:0.25]];
                screen = native_builtin_5k_screen(&selectedDisplayID);
                if (screen) break;
            } while (CACurrentMediaTime() < retryDeadline);
        }
        }
        if (!MTLCreateSystemDefaultDevice()) {
            fprintf(stderr,
                    "TB_PROTOCOL_METAL result=failed "
                    "reason=no-metal-device\n");
            tb_power_lifecycle_stop(&powerLifecycle);
            return 69;
        }
        NSWindow *window = [[TBApplianceWindow alloc]
            initWithContentRect:screen.frame
                      styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered
                          defer:NO
                         screen:screen];
        TBCursorShieldView *surfaceView = [[TBCursorShieldView alloc]
            initWithFrame:NSMakeRect(0.0, 0.0,
                                     NSWidth(screen.frame),
                                     NSHeight(screen.frame))];
        surfaceView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        window.contentView = surfaceView;
        [window setFrame:screen.frame display:NO];
        window.title = @"iMac 5K Display Appliance";
        window.releasedWhenClosed = NO;
        window.backgroundColor = [NSColor colorWithSRGBRed:0.035
                                                    green:0.051
                                                     blue:0.086
                                                    alpha:1.0];
        window.opaque = YES;
        // SSH-launched accessory apps can otherwise land on a non-active Space:
        // frames render successfully, but the user sees only the desktop (or
        // the window's initial black clear when changing Spaces). The bounded
        // diagnostic must be visibly present for end-to-end proof.
        window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                    NSWindowCollectionBehaviorFullScreenAuxiliary |
                                    NSWindowCollectionBehaviorStationary;
        // This Mac is acting as a display appliance while a sender is active.
        // Keep the iMac's Dock, menu bar, notifications, and desktop below the
        // receiver surface so none of its local UI leaks through the stream.
        window.level = (NSWindowLevel)CGShieldingWindowLevel();
        window.hidesOnDeactivate = NO;
        window.sharingType = NSWindowSharingReadOnly;

        NSView *idleOverlay = [[NSView alloc]
            initWithFrame:window.contentView.bounds];
        idleOverlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        idleOverlay.wantsLayer = YES;
        idleOverlay.layer.backgroundColor = [NSColor colorWithSRGBRed:0.035
                                                                green:0.051
                                                                 blue:0.086
                                                                alpha:1.0].CGColor;
        [window.contentView addSubview:idleOverlay];

        /* An opaque privacy cover is independent of the friendly idle UI.
         * It remains above the live Metal surface whenever this Aqua session
         * or app loses foreground ownership, while rendering/transport stay
         * alive underneath for a fast post-unlock recovery. */
        NSView *privacyOverlay = [[NSView alloc]
            initWithFrame:window.contentView.bounds];
        privacyOverlay.autoresizingMask =
            NSViewWidthSizable | NSViewHeightSizable;
        privacyOverlay.wantsLayer = YES;
        privacyOverlay.layer.backgroundColor = NSColor.blackColor.CGColor;
        privacyOverlay.accessibilityHidden = YES;
        privacyOverlay.hidden = NO;
        [window.contentView addSubview:privacyOverlay
                             positioned:NSWindowAbove
                             relativeTo:nil];

        NSTextField *titleLabel = [NSTextField labelWithString:
            @"iMac 5K Display Appliance"];
        titleLabel.alignment = NSTextAlignmentCenter;
        titleLabel.textColor = [NSColor colorWithSRGBRed:0.90
                                                    green:0.95
                                                     blue:1.00
                                                    alpha:1.0];
        titleLabel.font = [NSFont systemFontOfSize:44.0
                                         weight:NSFontWeightSemibold];

        NSTextField *statusLabel = [NSTextField labelWithString:
            @"Waiting for the MacBook"];
        statusLabel.alignment = NSTextAlignmentCenter;
        statusLabel.textColor = [NSColor colorWithSRGBRed:0.32
                                                     green:0.75
                                                      blue:1.00
                                                     alpha:1.0];
        statusLabel.font = [NSFont systemFontOfSize:22.0
                                          weight:NSFontWeightMedium];

        NSTextField *instructionLabel = [NSTextField labelWithString:
            @"Connect the Thunderbolt cable; the display starts automatically."];
        instructionLabel.alignment = NSTextAlignmentCenter;
        instructionLabel.textColor = [NSColor colorWithWhite:0.72 alpha:1.0];
        instructionLabel.font = [NSFont systemFontOfSize:15.0
                                               weight:NSFontWeightRegular];

        // A small native pull-down is visible only while idle. It makes the
        // appliance controllable without placing chrome over the live display.
        NSPopUpButton *optionsButton = [[NSPopUpButton alloc]
            initWithFrame:NSZeroRect pullsDown:YES];
        [optionsButton removeAllItems];
        [optionsButton addItemWithTitle:@"Options"];
        NSMenuItem *idleAboutItem = [[NSMenuItem alloc]
            initWithTitle:@"About iMac 5K Display Appliance"
                   action:@selector(orderFrontStandardAboutPanel:)
            keyEquivalent:@""];
        idleAboutItem.target = NSApp;
        [optionsButton.menu addItem:idleAboutItem];
        [optionsButton.menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *idleQuitItem = [[NSMenuItem alloc]
            initWithTitle:@"Quit iMac 5K Display Appliance"
                   action:@selector(requestGracefulQuit:)
            keyEquivalent:@""];
        idleQuitItem.target = menuController;
        [optionsButton.menu addItem:idleQuitItem];
        optionsButton.controlSize = NSControlSizeLarge;
        optionsButton.font = [NSFont systemFontOfSize:14.0
                                               weight:NSFontWeightMedium];
        optionsButton.accessibilityLabel = @"Display appliance options";

        NSStackView *idleStack = [NSStackView stackViewWithViews:@[
            titleLabel,
            statusLabel,
            instructionLabel,
            optionsButton
        ]];
        idleStack.orientation = NSUserInterfaceLayoutOrientationVertical;
        idleStack.alignment = NSLayoutAttributeCenterX;
        idleStack.spacing = 14.0;
        idleStack.translatesAutoresizingMaskIntoConstraints = NO;
        [idleOverlay addSubview:idleStack];
        [NSLayoutConstraint activateConstraints:@[
            [idleStack.centerXAnchor
                constraintEqualToAnchor:idleOverlay.centerXAnchor],
            [idleStack.centerYAnchor
                constraintEqualToAnchor:idleOverlay.centerYAnchor],
            [idleStack.leadingAnchor
                constraintGreaterThanOrEqualToAnchor:idleOverlay.leadingAnchor
                                             constant:48.0],
            [idleStack.trailingAnchor
                constraintLessThanOrEqualToAnchor:idleOverlay.trailingAnchor
                                          constant:-48.0]
        ]];
        TBReceiverPresentationController *presentationController =
            [[TBReceiverPresentationController alloc] initWithWindow:window];
        NSApp.delegate = presentationController;

        if (selectedDisplayID == kCGNullDirectDisplay ||
            !physical_panel_accepts_dpcm(
                window, selectedDisplayID, 5120, 2880)) {
            fprintf(stderr,
                    "TB_PROTOCOL_METAL result=failed "
                    "reason=physical-panel-preflight\n");
            [window close];
            tb_power_lifecycle_stop(&powerLifecycle);
            return 69;
        }

        void *renderer = tb_native_metal_create();
        const bool receiveOverlapEnabled =
            environment_flag_enabled("TB_RECEIVE_OVERLAP");
        uint8_t *payload = (uint8_t *)malloc(TB_MAX_PACKET_LENGTH - 1);
        uint8_t *payloadSecondary = receiveOverlapEnabled
            ? (uint8_t *)malloc(TB_MAX_PACKET_LENGTH - 1)
            : NULL;
        dispatch_queue_t receivePrefetchQueue = receiveOverlapEnabled
            ? dispatch_queue_create(
                "com.targetbridge.receiver5k.receive-prefetch",
                DISPATCH_QUEUE_SERIAL)
            : NULL;
        dispatch_semaphore_t receivePrefetchDone = receiveOverlapEnabled
            ? dispatch_semaphore_create(0)
            : NULL;
        /* Persistent appliance mode retains a rolling ten-second window at
         * the 60 FPS target. The old 36,000-entry first-ten-minute arrays were
         * bounded, but lazily dirtying their pages looked exactly like an RSS
         * leak during qualification and spent memory on stale startup data.
         * Bounded diagnostic runs retain every requested sample. */
        const uint32_t timingCapacity = serveForever ? 600 : expectedFrames;
        double *packetTimes = (double *)calloc(
            (size_t)timingCapacity, sizeof(*packetTimes));
        double *completionGaps = (double *)calloc(
            (size_t)timingCapacity, sizeof(*completionGaps));
        if (!renderer || !payload || !packetTimes || !completionGaps ||
            (receiveOverlapEnabled &&
             (!payloadSecondary || !receivePrefetchQueue ||
              !receivePrefetchDone))) {
            fprintf(stderr, "TB_PROTOCOL_METAL result=failed reason=allocation\n");
            free(completionGaps);
            free(packetTimes);
            free(payloadSecondary);
            free(payload);
            if (renderer) tb_native_metal_destroy(renderer);
            [window close];
            tb_power_lifecycle_stop(&powerLifecycle);
            return 70;
        }
        /* Hide Metal while idle. Session startup later makes its view drawable
         * behind the opaque cover and removes that cover only after a drawable
         * from the current presentation epoch reaches the screen. */
        tb_native_metal_set_visible(renderer, 0);

        void (^showIdleState)(NSString *, NSString *) =
            ^(NSString *status, NSString *instruction) {
            void (^updates)(void) = ^{
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                statusLabel.stringValue = status;
                instructionLabel.stringValue = instruction;
                idleOverlay.hidden = NO;
                idleOverlay.accessibilityHidden = NO;
                [window.contentView addSubview:idleOverlay
                                     positioned:NSWindowAbove
                                     relativeTo:nil];
                tb_native_metal_set_visible(renderer, 0);
                if (!privacyOverlay.hidden) {
                    [window.contentView addSubview:privacyOverlay
                                         positioned:NSWindowAbove
                                         relativeTo:nil];
                }
                [window orderFrontRegardless];
                [window displayIfNeeded];
                [window.contentView displayIfNeeded];
                [CATransaction commit];
                [CATransaction flush];
            };
            if ([NSThread isMainThread]) {
                updates();
            } else {
                dispatch_sync(dispatch_get_main_queue(), updates);
            }
        };
        void (^showLiveSurface)(void) = ^{
            void (^updates)(void) = ^{
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                // Keep the opaque cover above Metal until the prepared layer
                // is visible, then remove it in the same AppKit transaction.
                [window.contentView addSubview:idleOverlay
                                     positioned:NSWindowAbove
                                     relativeTo:nil];
                tb_native_metal_set_visible(renderer, 1);
                idleOverlay.accessibilityHidden = YES;
                idleOverlay.hidden = YES;
                if (!privacyOverlay.hidden) {
                    [window.contentView addSubview:privacyOverlay
                                         positioned:NSWindowAbove
                                         relativeTo:nil];
                }
                [CATransaction commit];
                [CATransaction flush];
            };
            if ([NSThread isMainThread]) {
                updates();
            } else {
                dispatch_sync(dispatch_get_main_queue(), updates);
            }
        };
        uint64_t (^beginCoveredPresentation)(void) = ^uint64_t {
            __block uint64_t epoch = 0;
            void (^updates)(void) = ^{
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                epoch = tb_native_metal_begin_presentation_session(renderer);
                // beginPresentationSession attaches Metal above existing views;
                // restore the opaque waiting cover as the topmost surface.
                [window.contentView addSubview:idleOverlay
                                     positioned:NSWindowAbove
                                     relativeTo:nil];
                if (!privacyOverlay.hidden) {
                    [window.contentView addSubview:privacyOverlay
                                         positioned:NSWindowAbove
                                         relativeTo:nil];
                }
                [CATransaction commit];
                [CATransaction flush];
            };
            if ([NSThread isMainThread]) {
                updates();
            } else {
                dispatch_sync(dispatch_get_main_queue(), updates);
            }
            return epoch;
        };
        // The benchmark receives synchronously below. Give AppKit/Core
        // Animation one main-run-loop turn so the visible waiting window reaches
        // WindowServer before accept() blocks. The Metal subview is attached by
        // the first frame, replacing this unmistakable diagnostic surface.
        [window displayIfNeeded];
        [window.contentView displayIfNeeded];
        [CATransaction flush];
        [[NSRunLoop currentRunLoop]
            runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];

        signal(SIGPIPE, SIG_IGN);
        /* Dispatch signal sources turn process termination into ordinary main-
         * queue work. No malloc, logging, Objective-C, or descriptor mutation
         * runs in a POSIX signal handler. */
        signal(SIGTERM, SIG_IGN);
        signal(SIGINT, SIG_IGN);
        int listener = make_listener((uint16_t)portValue);
        struct tb_shutdown_gate *shutdownGate =
            (struct tb_shutdown_gate *)calloc(1, sizeof(*shutdownGate));
        if (!shutdownGate || tb_shutdown_gate_init(shutdownGate) != 0 ||
            tb_shutdown_gate_publish_listener(shutdownGate, listener) != 0) {
            fprintf(stderr,
                    "TB_PROTOCOL_METAL result=failed reason=shutdown-gate-init\n");
            if (shutdownGate && shutdownGate->initialized) {
                tb_shutdown_gate_close_listener(shutdownGate, &listener);
                tb_shutdown_gate_destroy(shutdownGate);
            } else {
                close(listener);
            }
            free(shutdownGate);
            free(completionGaps);
            free(packetTimes);
            free(payloadSecondary);
            free(payload);
            tb_native_metal_destroy(renderer);
            [window close];
            tb_power_lifecycle_stop(&powerLifecycle);
            signal(SIGTERM, SIG_DFL);
            signal(SIGINT, SIG_DFL);
            return 78;
        }
        dispatch_source_t sigtermSource = termination_signal_source(
            SIGTERM, shutdownGate);
        dispatch_source_t sigintSource = termination_signal_source(
            SIGINT, shutdownGate);
        if (!sigtermSource || !sigintSource) {
            fprintf(stderr,
                    "TB_PROTOCOL_METAL result=failed reason=shutdown-signal-source\n");
            if (sigtermSource) dispatch_source_cancel(sigtermSource);
            if (sigintSource) dispatch_source_cancel(sigintSource);
            tb_shutdown_gate_close_listener(shutdownGate, &listener);
            /* A delivered signal event may already be queued on main and still
             * capture shutdownGate. Keep this tiny process-lifetime context
             * alive until the imminent return instead of risking a UAF. */
            free(completionGaps);
            free(packetTimes);
            free(payloadSecondary);
            free(payload);
            tb_native_metal_destroy(renderer);
            [window close];
            tb_power_lifecycle_stop(&powerLifecycle);
            signal(SIGTERM, SIG_DFL);
            signal(SIGINT, SIG_DFL);
            return 78;
        }
        const bool supportsDPCM = tb_native_metal_supports_dpcm(renderer) != 0;
        const unsigned boundedReceiveMiB = receiveOverlapEnabled ? 128u : 64u;
        TBBonjourPublisher *bonjour = [[TBBonjourPublisher alloc]
            initWithPort:(uint16_t)portValue supportsDPCM:supportsDPCM];
        if (serveForever) {
            printf("TB_PROTOCOL_METAL state=listening port=%d mode=serve "
                   "receiveOverlap=%s boundedBufferMiB=%u "
                   "timingWindowFrames=%u\n",
                   portValue,
                   receiveOverlapEnabled ? "true" : "false",
                   boundedReceiveMiB,
                   timingCapacity);
        } else {
            printf("TB_PROTOCOL_METAL state=listening port=%d "
                   "expectedFrames=%u receiveOverlap=%s "
                   "boundedBufferMiB=%u\n",
                   portValue,
                   expectedFrames,
                   receiveOverlapEnabled ? "true" : "false",
                   boundedReceiveMiB);
        }
        fflush(stdout);
        receiver_diagnostic(
            OS_LOG_TYPE_DEFAULT,
            "state=listening port=%d mode=%s dpcm=%s "
            "receiveOverlap=%s boundedBufferMiB=%u",
            portValue,
            serveForever ? "serve" : "bounded",
            supportsDPCM ? "true" : "false",
            receiveOverlapEnabled ? "true" : "false",
            boundedReceiveMiB);
        __block int exitCode = 0;
        __block bool localCursorHidden = false;
        struct tb_receiver_lifecycle_snapshot *lifecycleSnapshot =
            (struct tb_receiver_lifecycle_snapshot *)calloc(
                1, sizeof(*lifecycleSnapshot));
        if (!lifecycleSnapshot ||
            pthread_mutex_init(&lifecycleSnapshot->lock, NULL) != 0) {
            fprintf(stderr,
                    "TB_PROTOCOL_METAL result=failed reason=lifecycle-lock\n");
            dispatch_source_cancel(sigtermSource);
            dispatch_source_cancel(sigintSource);
            tb_shutdown_gate_close_listener(shutdownGate, &listener);
            [bonjour invalidate];
            tb_power_lifecycle_stop(&powerLifecycle);
            free(completionGaps);
            free(packetTimes);
            free(payloadSecondary);
            free(payload);
            tb_native_metal_destroy(renderer);
            [window close];
            free(lifecycleSnapshot);
            return 77;
        }
        presentationController.cursorActivationHandler = ^{
            surfaceView.suppressLocalCursor = YES;
            (void)ensure_global_cursor_hidden(
                selectedDisplayID,
                &localCursorHidden,
                "session=active");
        };
        presentationController.cursorDeactivationHandler = ^{
            (void)restore_global_cursor(
                selectedDisplayID,
                &localCursorHidden,
                "cursor-policy=release");
            surfaceView.suppressLocalCursor = NO;
        };
        presentationController.privacyBlankHandler = ^{
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            privacyOverlay.hidden = NO;
            [window.contentView addSubview:privacyOverlay
                                 positioned:NSWindowAbove
                                 relativeTo:nil];
            [window displayIfNeeded];
            [window.contentView displayIfNeeded];
            [CATransaction commit];
            [CATransaction flush];
        };
        presentationController.privacyResumeHandler = ^{
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            privacyOverlay.hidden = YES;
            [CATransaction commit];
            [CATransaction flush];
        };
        presentationController.displayPowerGateHandler = ^BOOL(BOOL active) {
            if (!active) {
                tb_power_lifecycle_end_session(&powerLifecycle);
                const BOOL released =
                    powerLifecycle.display_sleep_assertion == 0 &&
                    powerLifecycle.user_activity_assertion == 0;
                tb_receiver_lifecycle_snapshot_set_power_failure(
                    lifecycleSnapshot, !released);
                return released;
            }
            const BOOL began =
                tb_power_lifecycle_begin_session(&powerLifecycle) == 0;
            tb_receiver_lifecycle_snapshot_set_power_failure(
                lifecycleSnapshot, !began);
            return began;
        };
        presentationController.lifecycleStateHandler = ^(
            BOOL receiverSurfaceAvailable,
            uint64_t receiverEpoch,
            BOOL sourceAwake,
            BOOL framesAllowed,
            uint64_t presentationGeneration) {
            tb_receiver_lifecycle_snapshot_store(
                lifecycleSnapshot,
                receiverSurfaceAvailable,
                receiverEpoch,
                sourceAwake,
                framesAllowed,
                presentationGeneration);
        };
        [presentationController refreshLifecycleState];
        dispatch_queue_t transportQueue = dispatch_queue_create(
            "com.targetbridge.receiver5k.transport",
            DISPATCH_QUEUE_SERIAL);
        dispatch_group_t transportGroup = dispatch_group_create();
        if (!transportQueue || !transportGroup) {
            fprintf(stderr,
                    "TB_PROTOCOL_METAL result=failed reason=transport-queue\n");
            dispatch_source_cancel(sigtermSource);
            dispatch_source_cancel(sigintSource);
            tb_shutdown_gate_close_listener(shutdownGate, &listener);
            /* Signal handlers retain shutdownGate until process exit. */
            [bonjour invalidate];
            tb_power_lifecycle_stop(&powerLifecycle);
            free(completionGaps);
            free(packetTimes);
            free(payloadSecondary);
            free(payload);
            tb_native_metal_destroy(renderer);
            [window close];
            pthread_mutex_destroy(&lifecycleSnapshot->lock);
            free(lifecycleSnapshot);
            signal(SIGTERM, SIG_DFL);
            signal(SIGINT, SIG_DFL);
            return 77;
        }

        /* AppKit owns the process main loop continuously. The serial transport
         * worker is allowed to block in accept/recv, but every window/layer and
         * Metal renderer operation is synchronously marshalled back to main.
         * Because the worker cannot read the next packet until that submission
         * returns, payload remains a single bounded 64 MiB buffer and no hidden
         * latency-growing frame queue can form. */
        dispatch_group_async(transportGroup, transportQueue, ^{
        @autoreleasepool {
        do {
        @autoreleasepool {
        const int listenerWait =
            tb_shutdown_gate_wait_for_listener(shutdownGate, listener);
        if (listenerWait == ECANCELED) break;
        if (listenerWait != 0) {
            fprintf(stderr,
                    "TB_PROTOCOL_METAL error=listener-wait errno=%d message=%s\n",
                    listenerWait, strerror(listenerWait));
            exitCode = 73;
            break;
        }
        int peer = accept(listener, NULL, NULL);
        if (peer < 0) {
            if (tb_shutdown_gate_is_requested(shutdownGate)) break;
            if (errno == EINTR) continue;
            fprintf(stderr,
                    "TB_PROTOCOL_METAL error=accept errno=%d message=%s\n",
                    errno, strerror(errno));
            exitCode = 73;
            break;
        }
        if (tb_shutdown_gate_publish_peer(shutdownGate, peer) != 0) {
            tb_shutdown_gate_close_peer(shutdownGate, &peer);
            break;
        }
        if (tb_shutdown_gate_is_requested(shutdownGate)) {
            tb_shutdown_gate_close_peer(shutdownGate, &peer);
            break;
        }
        if (serveForever && !peer_arrived_via_bridge0_link_local(peer)) {
            tb_shutdown_gate_close_peer(shutdownGate, &peer);
            continue;
        }
        int requested = 4 * 1024 * 1024;
        (void)setsockopt(peer, SOL_SOCKET, SO_RCVBUF, &requested, sizeof(requested));
        if (serveForever) {
            const struct timeval idleTimeout = {
                .tv_sec = TB_SERVE_PEER_IDLE_TIMEOUT_SECONDS,
                .tv_usec = 0
            };
            if (setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO,
                           &idleTimeout, sizeof(idleTimeout)) != 0) {
                fprintf(stderr,
                        "TB_PROTOCOL_METAL error=peer-idle-timeout-config "
                        "errno=%d message=%s\n",
                        errno, strerror(errno));
                tb_shutdown_gate_close_peer(shutdownGate, &peer);
                exitCode = 75;
                break;
            }

            /* Discovery opens a short-lived UI-language connection, while
             * automatic path selection opens a TEST_DATA-only connection.
             * Neither is a display session. Consume them without sending a
             * profile, waking the panel, or taking a display assertion. */
            const CFTimeInterval firstPacketDeadline =
                CACurrentMediaTime() + TB_SERVE_PEER_IDLE_TIMEOUT_SECONDS;
            bool probeStarted = false;
            bool helloAccepted = false;
            for (;;) {
                uint8_t lengthBytes[4];
                errno = 0;
                const bool readLength = probeStarted
                    ? read_exact(peer, lengthBytes, sizeof(lengthBytes))
                    : read_exact_before(peer, lengthBytes,
                                        sizeof(lengthBytes),
                                        firstPacketDeadline);
                if (!readLength) break;

                const uint32_t packetLength = load_be32(lengthBytes);
                if (packetLength < 1 ||
                    packetLength > TB_PRE_SESSION_MAX_PACKET_LENGTH) {
                    break;
                }
                uint8_t packetType = 0;
                const bool readType = probeStarted
                    ? read_exact(peer, &packetType, 1)
                    : read_exact_before(peer, &packetType, 1,
                                        firstPacketDeadline);
                if (!readType) break;

                const enum tb_pre_session_action action =
                    tb_pre_session_classify(
                        probeStarted, packetLength, packetType);
                if (action == TB_PRE_SESSION_REJECT) break;
                const size_t packetPayloadLength =
                    (size_t)packetLength - 1;
                const bool payloadConsumed = probeStarted
                    ? discard_exact(peer, packetPayloadLength)
                    : discard_exact_before(
                        peer, packetPayloadLength, firstPacketDeadline);
                if (!payloadConsumed) break;

                if (action == TB_PRE_SESSION_PROMOTE_HELLO) {
                    helloAccepted = true;
                    break;
                }
                if (action == TB_PRE_SESSION_CLOSE_AUXILIARY) break;
                probeStarted = true;
            }
            if (!helloAccepted) {
                tb_shutdown_gate_close_peer(shutdownGate, &peer);
                if (tb_shutdown_gate_is_requested(shutdownGate)) break;
                continue;
            }
        }
        showIdleState(@"MacBook detected · starting",
                      @"Preparing the native 5K display stream.");
        if (!send_display_profile(peer, supportsDPCM)) {
            fprintf(stderr, "TB_PROTOCOL_METAL result=failed reason=profile-send\n");
            tb_shutdown_gate_close_peer(shutdownGate, &peer);
            tb_power_lifecycle_end_session(&powerLifecycle);
            if (tb_shutdown_gate_is_requested(shutdownGate)) break;
            if (serveForever) {
                showIdleState(@"Couldn’t start the stream · retrying",
                              @"Check that the sender is running on the MacBook.");
                continue;
            }
            exitCode = 71;
            break;
        }
        showIdleState(@"Connected · waiting for the first frame",
                      @"The native 5K display stream is starting.");
        uint64_t activeRendererPresentationEpoch =
            beginCoveredPresentation();
        if (activeRendererPresentationEpoch == 0) {
            fprintf(stderr,
                    "TB_PROTOCOL_METAL result=failed reason=surface-prepare\n");
            tb_shutdown_gate_close_peer(shutdownGate, &peer);
            tb_power_lifecycle_end_session(&powerLifecycle);
            if (tb_shutdown_gate_is_requested(shutdownGate)) break;
            if (serveForever) {
                showIdleState(@"Couldn’t prepare the display · retrying",
                              @"The receiver will try again automatically.");
                continue;
            }
            exitCode = 71;
            break;
        }
        dispatch_sync(dispatch_get_main_queue(), ^{
            if (!tb_shutdown_gate_is_requested(shutdownGate)) {
                presentationController.streamActive = YES;
            }
        });
        bool initialSurfaceAvailable = false;
        bool initialPowerFailure = false;
        uint64_t initialSurfaceEpoch = 0;
        tb_receiver_lifecycle_snapshot_load(
            lifecycleSnapshot,
            &initialSurfaceAvailable,
            &initialSurfaceEpoch,
            NULL,
            NULL,
            NULL,
            &initialPowerFailure);
        if (initialPowerFailure ||
            !send_receiver_surface_state(
                peer, initialSurfaceAvailable, initialSurfaceEpoch)) {
            fprintf(stderr,
                    "TB_PROTOCOL_METAL result=failed "
                    "reason=initial-lifecycle-state\n");
            tb_shutdown_gate_close_peer(shutdownGate, &peer);
            dispatch_sync(dispatch_get_main_queue(), ^{
                presentationController.streamActive = NO;
            });
            if (tb_shutdown_gate_is_requested(shutdownGate)) break;
            if (serveForever) continue;
            exitCode = 74;
            break;
        }
        printf("TB_PROTOCOL_METAL state=profile-sent capture=5120x2880 rawNV12=true dpcm=%s\n",
               supportsDPCM ? "true" : "false");
        fflush(stdout);
        receiver_diagnostic(
            OS_LOG_TYPE_DEFAULT,
            "session=profile-sent capture=5120x2880 dpcm=%s",
            supportsDPCM ? "true" : "false");

        struct tb_native_metal_stats sessionBaseline;
        tb_native_metal_get_stats(renderer, &sessionBaseline);
        uint32_t attemptedFrames = 0;
        uint32_t receivedFrames = 0;
        uint32_t rawFrames = 0;
        uint32_t dpcmFrames = 0;
        uint32_t ignoredPackets = 0;
        uint32_t malformedRawFrames = 0;
        uint32_t malformedDPCMFrames = 0;
        uint32_t queueDrops = 0;
        uint32_t rendererFailures = 0;
        uint64_t payloadBytes = 0;
        uint64_t sampledLumaCount = 0;
        uint64_t sampledBrightLumaCount = 0;
        uint8_t sampledLumaMin = UINT8_MAX;
        uint8_t sampledLumaMax = 0;
        double packetTotal = 0.0;
        double packetMax = 0.0;
        double previousCompletion = 0.0;
        double firstCompletion = 0.0;
        double lastCompletion = 0.0;
        bool sessionRejected = false;
        bool processFatal = false;
        bool physicalGateChecked = false;
        bool liveGPUCompletionLogged = false;
        uint64_t lastSentReceiverSurfaceEpoch = initialSurfaceEpoch;
        uint64_t acceptedFrameGeneration = 0;
        uint64_t rendererPresentationGeneration = 0;
        uint64_t pendingFreshGeneration = 0;
        uint64_t pendingFreshRendererEpoch = 0;
        size_t primaryPayloadHighWater = 0;
        size_t secondaryPayloadHighWater = 0;
        bool peerReadTimedOut = false;
        const char *sessionEndReason = "frame-limit";
        int sessionEndErrno = 0;
        uint32_t sessionEndPacketLength = 0;
        uint8_t sessionEndPacketType = 0;
        uint8_t *currentPayload = payload;
        uint8_t *nextPayload = payloadSecondary;
        __block struct tb_wire_packet prefetchedPacket;
        memset(&prefetchedPacket, 0, sizeof(prefetchedPacket));
        __block bool receivePrefetchInFlight = false;
        uint64_t receivePrefetchPackets = 0;
        __block uint64_t receivePrefetchAborts = 0;
        double receivePrefetchWaitTotalMS = 0.0;
        double receivePrefetchWaitMaxMS = 0.0;

        void (^cancelReceivePrefetch)(void) = ^{
            if (!receivePrefetchInFlight) return;
            receivePrefetchAborts++;
            (void)shutdown(peer, SHUT_RDWR);
            const long waitResult = dispatch_semaphore_wait(
                receivePrefetchDone,
                dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
            if (waitResult != 0) {
                /* The task may still own the secondary slot. Never continue
                 * into ordinary teardown/free on an unproven completion. */
                dispatch_sync(dispatch_get_main_queue(), ^{
                    (void)restore_global_cursor(
                        selectedDisplayID,
                        &localCursorHidden,
                        "prefetch-timeout");
                    surfaceView.suppressLocalCursor = NO;
                });
                tb_power_lifecycle_end_session(&powerLifecycle);
                receiver_diagnostic(
                    OS_LOG_TYPE_FAULT,
                    "shutdown=failed reason=prefetch-cancel-timeout "
                    "buffer=quarantined process=fail-fast");
                _exit(79);
            }
            receivePrefetchInFlight = false;
        };

        while (attemptedFrames < expectedFrames &&
               !tb_shutdown_gate_is_requested(shutdownGate)) {
            @autoreleasepool {
            // These describe the packet that ended this loop iteration, not a
            // previously accepted control or frame packet.
            sessionEndErrno = 0;
            sessionEndPacketLength = 0;
            sessionEndPacketType = 0;
            uint64_t currentPresentationGeneration = 0;
            tb_receiver_lifecycle_snapshot_load(
                lifecycleSnapshot,
                NULL,
                NULL,
                NULL,
                NULL,
                &currentPresentationGeneration,
                NULL);
            struct tb_native_metal_stats liveStats;
            tb_native_metal_get_runtime_stats(renderer, &liveStats);
            if (pendingFreshGeneration != 0 &&
                pendingFreshGeneration != currentPresentationGeneration) {
                pendingFreshGeneration = 0;
                pendingFreshRendererEpoch = 0;
            }
            if (pendingFreshGeneration != 0 &&
                pendingFreshRendererEpoch != 0 &&
                liveStats.last_presented_epoch >=
                    pendingFreshRendererEpoch) {
                const uint64_t presentedGeneration = pendingFreshGeneration;
                const uint64_t presentedEpoch = pendingFreshRendererEpoch;
                pendingFreshGeneration = 0;
                pendingFreshRendererEpoch = 0;
                __block BOOL acceptedPresentation = NO;
                dispatch_sync(dispatch_get_main_queue(), ^{
                    acceptedPresentation = [presentationController
                        markFreshFramePresentedForGeneration:
                            presentedGeneration];
                });
                if (acceptedPresentation) {
                    showLiveSurface();
                    receiver_diagnostic(
                        OS_LOG_TYPE_DEFAULT,
                        "lifecycle-generation=%llu presentedEpoch=%llu",
                        (unsigned long long)presentedGeneration,
                        (unsigned long long)presentedEpoch);
                }
            }
            if (liveStats.gpu_error_frames >
                sessionBaseline.gpu_error_frames) {
                rendererFailures++;
                processFatal = true;
                sessionEndReason = "renderer-gpu-error-before-read";
                break;
            }
            struct tb_wire_packet packet;
            if (receivePrefetchInFlight) {
                const double waitStarted = CACurrentMediaTime();
                const long waitResult = dispatch_semaphore_wait(
                    receivePrefetchDone,
                    dispatch_time(DISPATCH_TIME_NOW, 17 * NSEC_PER_SEC));
                if (waitResult != 0) {
                    processFatal = true;
                    sessionEndReason = "receive-prefetch-timeout";
                    cancelReceivePrefetch();
                    break;
                }
                const double waitMS =
                    (CACurrentMediaTime() - waitStarted) * 1000.0;
                receivePrefetchWaitTotalMS += waitMS;
                if (waitMS > receivePrefetchWaitMaxMS) {
                    receivePrefetchWaitMaxMS = waitMS;
                }
                receivePrefetchInFlight = false;
                packet = prefetchedPacket;
                uint8_t *previousPayload = currentPayload;
                currentPayload = nextPayload;
                nextPayload = previousPayload;
                receivePrefetchPackets++;
            } else {
                packet = read_wire_packet(peer, currentPayload);
            }

            sessionEndErrno = packet.error_number;
            sessionEndPacketLength = packet.packet_length;
            sessionEndPacketType = packet.packet_type;
            peerReadTimedOut =
                packet.error_number == EAGAIN ||
                packet.error_number == EWOULDBLOCK;
            if (packet.result != TB_WIRE_PACKET_READ_OK) {
                switch (packet.result) {
                case TB_WIRE_PACKET_READ_LENGTH_FAILED:
                    sessionEndReason = peerReadTimedOut
                        ? "packet-length-timeout"
                        : (packet.error_number == 0
                            ? "peer-closed-before-packet-length"
                            : "packet-length-read-error");
                    break;
                case TB_WIRE_PACKET_READ_INVALID_LENGTH:
                    sessionEndReason = "invalid-packet-length";
                    sessionRejected = true;
                    fprintf(stderr,
                            "TB_PROTOCOL_METAL error=invalid-packet-length value=%u\n",
                            packet.packet_length);
                    break;
                case TB_WIRE_PACKET_READ_TYPE_FAILED:
                    sessionEndReason = peerReadTimedOut
                        ? "packet-type-timeout"
                        : (packet.error_number == 0
                            ? "peer-closed-before-packet-type"
                            : "packet-type-read-error");
                    break;
                case TB_WIRE_PACKET_READ_PAYLOAD_FAILED:
                    sessionEndReason = peerReadTimedOut
                        ? "packet-payload-timeout"
                        : (packet.error_number == 0
                            ? "peer-closed-during-packet-payload"
                            : "packet-payload-read-error");
                    break;
                case TB_WIRE_PACKET_READ_OK:
                    break;
                }
                break;
            }
            const uint8_t packetType = packet.packet_type;
            const size_t payloadLength = packet.payload_length;
            if (currentPayload == payload) {
                if (payloadLength > primaryPayloadHighWater) {
                    primaryPayloadHighWater = payloadLength;
                }
            } else if (payloadLength > secondaryPayloadHighWater) {
                secondaryPayloadHighWater = payloadLength;
            }
            const double packetStarted = packet.payload_started;
            const double completed = packet.completed;

            bool receiverSurfaceAvailable = false;
            bool sourceAwake = true;
            bool framesAllowed = false;
            bool powerGateFailed = false;
            uint64_t receiverSurfaceEpoch = 0;
            uint64_t presentationGeneration = 0;
            tb_receiver_lifecycle_snapshot_load(
                lifecycleSnapshot,
                &receiverSurfaceAvailable,
                &receiverSurfaceEpoch,
                &sourceAwake,
                &framesAllowed,
                &presentationGeneration,
                &powerGateFailed);
            if (powerGateFailed) {
                sessionRejected = true;
                sessionEndReason = "display-power-gate-failed";
                break;
            }
            if (receiverSurfaceEpoch != lastSentReceiverSurfaceEpoch) {
                if (!send_receiver_surface_state(
                        peer,
                        receiverSurfaceAvailable,
                        receiverSurfaceEpoch)) {
                    sessionEndReason = "surface-state-send-failed";
                    break;
                }
                lastSentReceiverSurfaceEpoch = receiverSurfaceEpoch;
            }

            if (packetType == TB_PACKET_SOURCE_DISPLAY_STATE) {
                int awake = 0;
                uint64_t sourceEpoch = 0;
                uint64_t acknowledgedReceiverEpoch = 0;
                if (!tb_display_lifecycle_parse_state_json(
                        currentPayload,
                        payloadLength,
                        "awake",
                        &awake,
                        &sourceEpoch) ||
                    !tb_display_lifecycle_parse_uint64_json(
                        currentPayload,
                        payloadLength,
                        "receiverEpoch",
                        &acknowledgedReceiverEpoch)) {
                    sessionRejected = true;
                    sessionEndReason = "malformed-source-display-state";
                    fprintf(stderr,
                            "TB_PROTOCOL_METAL error=malformed-source-display-state "
                            "payload=%zu\n",
                            payloadLength);
                    cancelReceivePrefetch();
                    break;
                }
                __block enum tb_display_lifecycle_update update =
                    TB_DISPLAY_LIFECYCLE_INVALID;
                dispatch_sync(dispatch_get_main_queue(), ^{
                    update = [presentationController
                        applySourceDisplayAwake:awake != 0
                                           epoch:sourceEpoch
                                   receiverEpoch:acknowledgedReceiverEpoch];
                });
                if (update == TB_DISPLAY_LIFECYCLE_STALE) {
                    receiver_diagnostic(
                        OS_LOG_TYPE_DEFAULT,
                        "display-lifecycle=source-state-ignored "
                        "reason=stale epoch=%llu",
                        (unsigned long long)sourceEpoch);
                }
                if (update == TB_DISPLAY_LIFECYCLE_APPLIED) {
                    pendingFreshGeneration = 0;
                    pendingFreshRendererEpoch = 0;
                }
                continue;
            }

            if (packetType == TB_PACKET_VIDEO_PARAMETERS ||
                packetType == TB_PACKET_VIDEO_FRAME) {
                fprintf(stderr,
                        "TB_PROTOCOL_METAL error=unsupported-encoded-video "
                        "packetType=0x%02x; lossless DPCM/RAW required\n",
                        packetType);
                sessionRejected = true;
                sessionEndReason = "encoded-video-rejected";
                break;
            }
            if (packetType != TB_PACKET_RAW_FRAME &&
                packetType != TB_PACKET_DPCM_FRAME) {
                ignoredPackets++;
                continue;
            }
            /* The whole wire packet is already in the one bounded slot. Drop
             * it before parse/Metal work while either public lifecycle gate is
             * closed; no partial TBD2 state is retained between packets. */
            if (!framesAllowed && receiverSurfaceAvailable && sourceAwake) {
                __block BOOL legacyFrameAllowed = NO;
                __block uint64_t legacyGeneration = 0;
                dispatch_sync(dispatch_get_main_queue(), ^{
                    legacyFrameAllowed = [presentationController
                        admitLegacyFrameForGeneration:&legacyGeneration];
                });
                if (legacyFrameAllowed) {
                    framesAllowed = true;
                    presentationGeneration = legacyGeneration;
                }
            }
            if (!framesAllowed) {
                ignoredPackets++;
                continue;
            }
            acceptedFrameGeneration = presentationGeneration;
            attemptedFrames++;

            struct tb_raw_nv12_view frame;
            memset(&frame, 0, sizeof(frame));
            struct tb_dpcm_info dpcm;
            memset(&dpcm, 0, sizeof(dpcm));
            __block int renderResult = -1;
            if (packetType == TB_PACKET_RAW_FRAME) {
                if (!tb_raw_nv12_parse(
                        currentPayload, payloadLength, &frame) ||
                    frame.width != 5120 || frame.height != 2880) {
                    malformedRawFrames++;
                    fprintf(stderr,
                            "TB_PROTOCOL_METAL error=malformed-raw-frame payload=%zu\n",
                            payloadLength);
                    sessionRejected = true;
                    sessionEndReason = "malformed-raw-frame";
                    break;
                }
            } else {
                if (!supportsDPCM ||
                    tb_dpcm_parse(
                        currentPayload, payloadLength, &dpcm) != 0 ||
                    dpcm.width != 5120 || dpcm.height != 2880 ||
                    dpcm.ten_bit || !dpcm.alpha_omitted) {
                    malformedDPCMFrames++;
                    fprintf(stderr,
                            "TB_PROTOCOL_METAL error=malformed-or-unsupported-dpcm-frame payload=%zu\n",
                            payloadLength);
                    sessionRejected = true;
                    sessionEndReason = "malformed-or-unsupported-dpcm-frame";
                    break;
                }
                if (!physicalGateChecked) {
                    physicalGateChecked = true;
                    __block bool panelAccepted = false;
                    dispatch_sync(dispatch_get_main_queue(), ^{
                        panelAccepted = physical_panel_accepts_dpcm(
                            window, selectedDisplayID,
                            dpcm.width, dpcm.height);
                    });
                    if (!panelAccepted) {
                        sessionRejected = true;
                        sessionEndReason = "physical-panel-gate-rejected";
                        break;
                    }
                }
            }

            if (acceptedFrameGeneration != rendererPresentationGeneration) {
                const uint64_t nextRendererEpoch = beginCoveredPresentation();
                if (nextRendererEpoch == 0) {
                    sessionRejected = true;
                    sessionEndReason = "lifecycle-presentation-prepare-failed";
                    cancelReceivePrefetch();
                    break;
                }
                activeRendererPresentationEpoch = nextRendererEpoch;
                rendererPresentationGeneration = acceptedFrameGeneration;
                pendingFreshGeneration = acceptedFrameGeneration;
                pendingFreshRendererEpoch = nextRendererEpoch;
            }

            /* Read packet n+1 into the other fixed slot while main submits
             * packet n. There is never more than one prefetch task, and the
             * slot is not swapped/reused until its completion semaphore has
             * established that read_wire_packet returned. */
            if (receiveOverlapEnabled &&
                attemptedFrames < expectedFrames &&
                !tb_shutdown_gate_is_requested(shutdownGate)) {
                NSCAssert(!receivePrefetchInFlight,
                          @"receive prefetch must be single-flight");
                uint8_t *prefetchTarget = nextPayload;
                receivePrefetchInFlight = true;
                dispatch_async(receivePrefetchQueue, ^{
                    @try {
                        prefetchedPacket =
                            read_wire_packet(peer, prefetchTarget);
                    } @finally {
                        dispatch_semaphore_signal(receivePrefetchDone);
                    }
                });
            }

            if (packetType == TB_PACKET_RAW_FRAME) {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    renderResult = tb_native_metal_render_nv12_planes(
                        renderer,
                        frame.y, (int)frame.y_stride,
                        frame.uv, (int)frame.uv_stride,
                        (int)frame.width, (int)frame.height,
                        0, 0, (int)frame.width, (int)frame.height,
                        0, 0, 0);
                    [CATransaction flush];
                });
            } else {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    renderResult = tb_native_metal_render_dpcm(
                        renderer, currentPayload, payloadLength,
                        0, 0, dpcm.width, dpcm.height, 0, 0, 0);
                    [CATransaction flush];
                });
            }
            if (renderResult == 0) {
                queueDrops++;
                if (packetType == TB_PACKET_DPCM_FRAME) {
                    sessionRejected = true;
                    sessionEndReason = "dpcm-render-queue-full";
                    cancelReceivePrefetch();
                    break;
                }
                continue;
            }
            if (renderResult == TB_NATIVE_METAL_RENDER_TRANSIENT_RETRY) {
                sessionRejected = true;
                sessionEndReason = "renderer-transient-retry";
                cancelReceivePrefetch();
                break;
            }
            if (renderResult < 0) {
                rendererFailures++;
                processFatal = true;
                sessionEndReason = "renderer-submit-failed";
                cancelReceivePrefetch();
                break;
            }
            const double packetMilliseconds =
                (completed - packetStarted) * 1000.0;
            if (receivedFrames == 0) firstCompletion = completed;
            if (previousCompletion > 0.0 && receivedFrames > 0) {
                const uint32_t gapIndex =
                    (receivedFrames - 1) % timingCapacity;
                completionGaps[gapIndex] =
                    (completed - previousCompletion) * 1000.0;
            }
            previousCompletion = completed;
            lastCompletion = completed;
            packetTimes[receivedFrames % timingCapacity] = packetMilliseconds;
            packetTotal += packetMilliseconds;
            if (packetMilliseconds > packetMax) packetMax = packetMilliseconds;
            payloadBytes += payloadLength;
            receivedFrames++;

            if (packetType == TB_PACKET_DPCM_FRAME) {
                dpcmFrames++;
            } else {
                rawFrames++;
            }

            if (packetType == TB_PACKET_RAW_FRAME &&
                snapshotPath && receivedFrames == 120) {
                const bool snapshotWritten = write_luma_snapshot(snapshotPath, &frame);
                printf("TB_PROTOCOL_METAL snapshot=%s path=%s frame=120 size=640x360\n",
                       snapshotWritten ? "written" : "failed",
                       snapshotPath);
                fflush(stdout);
            }

            // A sparse grid proves whether real, non-black image content made
            // it onto the wire without dumping frames or materially taxing the
            // receiver. Video-range black is Y=16; >32 is visibly non-black.
            if (packetType == TB_PACKET_RAW_FRAME) {
                for (uint32_t y = 0; y < frame.height; y += 64) {
                    const uint8_t *row = frame.y + (size_t)y * frame.y_stride;
                    for (uint32_t x = 0; x < frame.width; x += 64) {
                        const uint8_t luma = row[x];
                        if (luma < sampledLumaMin) sampledLumaMin = luma;
                        if (luma > sampledLumaMax) sampledLumaMax = luma;
                        if (luma > 32) sampledBrightLumaCount++;
                        sampledLumaCount++;
                    }
                }
            }

            tb_native_metal_get_runtime_stats(renderer, &liveStats);
            const uint64_t sessionCompleted =
                liveStats.completed_frames - sessionBaseline.completed_frames;
            const uint64_t sessionGPUErrors =
                liveStats.gpu_error_frames - sessionBaseline.gpu_error_frames;
            if (!liveGPUCompletionLogged &&
                sessionCompleted > sessionGPUErrors) {
                liveGPUCompletionLogged = true;
                printf("TB_PROTOCOL_METAL state=live gpuCompleted=%llu "
                       "gpuSuccessful=%llu gpuErrors=%llu submitted=%llu\n",
                       (unsigned long long)sessionCompleted,
                       (unsigned long long)(sessionCompleted - sessionGPUErrors),
                       (unsigned long long)sessionGPUErrors,
                       (unsigned long long)(liveStats.submitted_frames -
                                            sessionBaseline.submitted_frames));
                fflush(stdout);
                receiver_diagnostic(
                    OS_LOG_TYPE_DEFAULT,
                    "session=live gpuSuccessful=%llu submitted=%llu",
                    (unsigned long long)(sessionCompleted - sessionGPUErrors),
                    (unsigned long long)(liveStats.submitted_frames -
                                         sessionBaseline.submitted_frames));
            }
            if (sessionGPUErrors > 0) {
                rendererFailures++;
                processFatal = true;
                sessionEndReason = "renderer-gpu-error-after-submit";
                cancelReceivePrefetch();
                break;
            }
            }
        }

        /* A shutdown request can make the while condition false after packet
         * n scheduled the read of n+1. Close the socket before waiting so the
         * fixed prefetch task cannot outlive its session buffer or peer. */
        cancelReceivePrefetch();

        struct tb_native_metal_stats stats;
        const CFTimeInterval deadline = CACurrentMediaTime() + 3.0;
        bool presentationDrainFinished = false;
        bool presentationDrainTimedOut = false;
        bool presentationInvariantViolation = false;
        do {
            tb_native_metal_get_stats(renderer, &stats);
            const uint64_t sessionSubmittedNow =
                stats.submitted_frames - sessionBaseline.submitted_frames;
            const uint64_t sessionCompletedNow =
                stats.completed_frames - sessionBaseline.completed_frames;
            const uint64_t sessionGPUErrorsNow =
                stats.gpu_error_frames - sessionBaseline.gpu_error_frames;
            const uint64_t sessionPresentedNow =
                stats.presented_frames - sessionBaseline.presented_frames;
            const uint64_t sessionPresentationDropsNow =
                stats.presentation_dropped_frames -
                sessionBaseline.presentation_dropped_frames;
            const int presentationState =
                tb_native_metal_presentation_resolution_state(
                    sessionSubmittedNow,
                    sessionPresentedNow,
                    sessionPresentationDropsNow);
            if (presentationState ==
                TB_NATIVE_METAL_PRESENTATION_INVARIANT) {
                presentationInvariantViolation = true;
                break;
            }
            /* A failed GPU command may never produce a normal drawable
             * presentation outcome. Completion still supplies the teardown
             * barrier; acceptance below remains fail-closed on the GPU error. */
            if (sessionCompletedNow == sessionSubmittedNow &&
                (sessionGPUErrorsNow > 0 ||
                 presentationState == TB_NATIVE_METAL_PRESENTATION_DRAINED)) {
                presentationDrainFinished = true;
                break;
            }
            usleep(5000);
        } while (CACurrentMediaTime() < deadline);
        /* Reclassify from one final atomic stats snapshot. A callback can land
         * after the final sleep crosses the deadline but before this read; the
         * completed outcome must not be reported as a timeout merely because
         * the preceding loop snapshot was stale. */
        tb_native_metal_get_stats(renderer, &stats);
        const uint64_t finalSubmittedFrames =
            stats.submitted_frames - sessionBaseline.submitted_frames;
        const uint64_t finalCompletedFrames =
            stats.completed_frames - sessionBaseline.completed_frames;
        const uint64_t finalGPUErrorFrames =
            stats.gpu_error_frames - sessionBaseline.gpu_error_frames;
        const uint64_t finalPresentedFrames =
            stats.presented_frames - sessionBaseline.presented_frames;
        const uint64_t finalPresentationDroppedFrames =
            stats.presentation_dropped_frames -
            sessionBaseline.presentation_dropped_frames;
        const int finalPresentationState =
            tb_native_metal_presentation_resolution_state(
                finalSubmittedFrames,
                finalPresentedFrames,
                finalPresentationDroppedFrames);
        presentationInvariantViolation =
            finalPresentationState == TB_NATIVE_METAL_PRESENTATION_INVARIANT;
        presentationDrainFinished =
            !presentationInvariantViolation &&
            finalCompletedFrames == finalSubmittedFrames &&
            (finalGPUErrorFrames > 0 ||
             finalPresentationState == TB_NATIVE_METAL_PRESENTATION_DRAINED);
        /* A failed GPU command is already a terminal outcome and may never
         * receive a presentation callback. Do not mislabel that case as a
         * presentation timeout. Likewise, a completed presentation timeline
         * with an outstanding GPU completion is solely a GPU drain failure. */
        presentationDrainTimedOut =
            !presentationDrainFinished &&
            !presentationInvariantViolation &&
            finalGPUErrorFrames == 0 &&
            finalPresentationState == TB_NATIVE_METAL_PRESENTATION_PENDING;
        if (pendingFreshGeneration != 0 &&
            pendingFreshRendererEpoch != 0 &&
            stats.last_presented_epoch >= pendingFreshRendererEpoch) {
            uint64_t currentGeneration = 0;
            tb_receiver_lifecycle_snapshot_load(
                lifecycleSnapshot, NULL, NULL, NULL, NULL,
                &currentGeneration, NULL);
            if (currentGeneration == pendingFreshGeneration) {
                const uint64_t presentedGeneration = pendingFreshGeneration;
                pendingFreshGeneration = 0;
                pendingFreshRendererEpoch = 0;
                __block BOOL acceptedPresentation = NO;
                dispatch_sync(dispatch_get_main_queue(), ^{
                    acceptedPresentation = [presentationController
                        markFreshFramePresentedForGeneration:
                            presentedGeneration];
                });
                if (acceptedPresentation) showLiveSurface();
            }
        }
        const uint64_t submittedFrames =
            stats.submitted_frames - sessionBaseline.submitted_frames;
        const uint64_t completedFrames =
            stats.completed_frames - sessionBaseline.completed_frames;
        const uint64_t gpuErrorFrames =
            stats.gpu_error_frames - sessionBaseline.gpu_error_frames;
        const uint64_t droppedFrames =
            stats.dropped_frames - sessionBaseline.dropped_frames;
        const uint64_t presentedFrames =
            stats.presented_frames - sessionBaseline.presented_frames;
        const uint64_t presentationDroppedFrames =
            stats.presentation_dropped_frames -
            sessionBaseline.presentation_dropped_frames;
        const uint64_t currentEpochPresentedFrames =
            stats.presentation_epoch == activeRendererPresentationEpoch
                ? stats.presentation_epoch_presented_frames
                : 0;
        const double presentedElapsed =
            currentEpochPresentedFrames > 1
                ? stats.presentation_epoch_last_time -
                    stats.presentation_epoch_first_time
                : 0.0;
        const double presentedFPS = presentedElapsed > 0.0
            ? (double)(currentEpochPresentedFrames - 1) / presentedElapsed
            : 0.0;
        const uint64_t dpcmUploadAllocations =
            stats.dpcm_upload_buffer_allocations -
            sessionBaseline.dpcm_upload_buffer_allocations;
        const uint64_t dpcmDecodedAllocations =
            stats.dpcm_decoded_buffer_allocations -
            sessionBaseline.dpcm_decoded_buffer_allocations;
        const uint64_t dpcmTextureViewCreations =
            stats.dpcm_texture_view_creations -
            sessionBaseline.dpcm_texture_view_creations;
        const int64_t metalAllocatedDeltaBytes =
            (int64_t)stats.device_current_allocated_bytes -
            (int64_t)sessionBaseline.device_current_allocated_bytes;
        if (!liveGPUCompletionLogged && completedFrames > gpuErrorFrames) {
            liveGPUCompletionLogged = true;
            printf("TB_PROTOCOL_METAL state=live gpuCompleted=%llu "
                   "gpuSuccessful=%llu gpuErrors=%llu submitted=%llu\n",
                   (unsigned long long)completedFrames,
                   (unsigned long long)(completedFrames - gpuErrorFrames),
                   (unsigned long long)gpuErrorFrames,
                   (unsigned long long)submittedFrames);
            fflush(stdout);
            receiver_diagnostic(
                OS_LOG_TYPE_DEFAULT,
                "session=live gpuSuccessful=%llu submitted=%llu",
                (unsigned long long)(completedFrames - gpuErrorFrames),
                (unsigned long long)submittedFrames);
        }
        if (presentationInvariantViolation) {
            rendererFailures++;
            processFatal = true;
            sessionEndReason = "presentation-accounting-invariant";
            fprintf(stderr,
                    "TB_PROTOCOL_METAL error=presentation-accounting-invariant "
                    "epoch=%llu activeEpoch=%llu submitted=%llu "
                    "presented=%llu presentationDrops=%llu\n",
                    (unsigned long long)stats.presentation_epoch,
                    (unsigned long long)activeRendererPresentationEpoch,
                    (unsigned long long)submittedFrames,
                    (unsigned long long)presentedFrames,
                    (unsigned long long)presentationDroppedFrames);
        }
        if (gpuErrorFrames > 0 && !processFatal) {
            rendererFailures++;
            processFatal = true;
            sessionEndReason = "renderer-gpu-error-during-drain";
        }
        if (completedFrames != submittedFrames && !processFatal) {
            rendererFailures++;
            processFatal = true;
            sessionEndReason = "gpu-completion-timeout";
            fprintf(stderr,
                    "TB_PROTOCOL_METAL error=gpu-completion-timeout "
                    "submitted=%llu completed=%llu\n",
                    (unsigned long long)submittedFrames,
                    (unsigned long long)completedFrames);
        }
        if (presentationDrainTimedOut && !processFatal) {
            rendererFailures++;
            sessionEndReason = "presentation-callback-timeout";
            fprintf(stderr,
                    "TB_PROTOCOL_METAL error=presentation-callback-timeout "
                    "submitted=%llu presented=%llu presentationDrops=%llu\n",
                    (unsigned long long)submittedFrames,
                    (unsigned long long)presentedFrames,
                    (unsigned long long)presentationDroppedFrames);
        }

        const uint32_t timingCount = receivedFrames < timingCapacity
            ? receivedFrames : timingCapacity;
        const uint32_t availableGaps = receivedFrames > 1
            ? receivedFrames - 1 : 0;
        const uint32_t gapCount = availableGaps < timingCapacity
            ? availableGaps : timingCapacity;
        const double elapsed =
            receivedFrames > 1 ? lastCompletion - firstCompletion : 0.0;
        const double actualFPS =
            elapsed > 0.0 ? (double)(receivedFrames - 1) / elapsed : 0.0;
        const uint32_t malformedFrames =
            malformedRawFrames + malformedDPCMFrames;
        const bool ok = (serveForever || receivedFrames == expectedFrames) &&
                        malformedFrames == 0 &&
                        queueDrops == 0 &&
                        rendererFailures == 0 &&
                        !sessionRejected &&
                        !processFatal &&
                        !presentationDrainTimedOut &&
                        !presentationInvariantViolation &&
                        gpuErrorFrames == 0 &&
                        droppedFrames == 0 &&
                        presentationDroppedFrames == 0 &&
                        completedFrames == submittedFrames &&
                        presentedFrames == submittedFrames;
        printf(
            "TB_PROTOCOL_METAL result=%s attempted=%u received=%u raw=%u dpcm=%u "
            "ignored=%u malformed=%u malformedRaw=%u malformedDPCM=%u "
            "queueDrops=%u rendererFailures=%u "
            "peerIdleTimeout=%s sessionRejected=%s processFatal=%s "
            "actualFPS=%.3f payloadGbps=%.3f submitted=%llu completed=%llu "
            "presented=%llu presentationDrops=%llu presentedFPS=%.3f "
            "presentationDrainTimedOut=%s presentationInvariant=%s "
            "presentCallbacksOutOfOrder=%llu "
            "presentGapP50=%.3fms presentGapP95=%.3fms "
            "presentGapP99=%.3fms presentGapMax=%.3fms "
            "gpuErrors=%llu dropped=%llu inflightMax=%llu "
            "lumaMin=%u lumaMax=%u brightSamples=%.2f%% packetReadAvg=%.3fms "
            "packetReadP50=%.3fms packetReadP95=%.3fms "
            "packetReadP99=%.3fms packetReadMax=%.3fms "
            "receiveOverlap=%s prefetchPackets=%llu prefetchAborts=%llu "
            "primaryPayloadHighWater=%zu secondaryPayloadHighWater=%zu "
            "prefetchWaitAvg=%.3fms prefetchWaitMax=%.3fms "
            "completionGapP50=%.3fms completionGapP95=%.3fms "
            "completionGapP99=%.3fms rawCopyP99=%.2fms "
            "submitP99=%.2fms gpuP99=%.2fms color=%s "
            "dpcmUploadAllocs=%llu dpcmDecodedAllocs=%llu "
            "dpcmTextureViews=%llu dpcmUploadMiB=%.2f dpcmDecodedMiB=%.2f\n",
            serveForever ? (ok ? "serve-ended" : "failed") : (ok ? "ok" : "failed"),
            attemptedFrames, receivedFrames, rawFrames, dpcmFrames,
            ignoredPackets, malformedFrames, malformedRawFrames,
            malformedDPCMFrames, queueDrops, rendererFailures,
            peerReadTimedOut ? "true" : "false",
            sessionRejected ? "true" : "false",
            processFatal ? "true" : "false",
            actualFPS,
            elapsed > 0.0 ? (double)payloadBytes * 8.0 / elapsed / 1e9 : 0.0,
            (unsigned long long)submittedFrames,
            (unsigned long long)completedFrames,
            (unsigned long long)presentedFrames,
            (unsigned long long)presentationDroppedFrames,
            presentedFPS,
            presentationDrainTimedOut ? "true" : "false",
            presentationInvariantViolation ? "failed" : "ok",
            (unsigned long long)
                stats.presentation_epoch_out_of_order_callbacks,
            renderer_histogram_percentile(
                stats.presentation_epoch_gap_histogram, 50),
            renderer_histogram_percentile(
                stats.presentation_epoch_gap_histogram, 95),
            renderer_histogram_percentile(
                stats.presentation_epoch_gap_histogram, 99),
            stats.presentation_epoch_gap_ms_max,
            (unsigned long long)gpuErrorFrames,
            (unsigned long long)droppedFrames,
            (unsigned long long)stats.inflight_frames_max,
            sampledLumaCount ? sampledLumaMin : 0,
            sampledLumaCount ? sampledLumaMax : 0,
            sampledLumaCount
                ? 100.0 * (double)sampledBrightLumaCount / (double)sampledLumaCount
                : 0.0,
            receivedFrames ? packetTotal / receivedFrames : 0.0,
            percentile(packetTimes, timingCount, 50),
            percentile(packetTimes, timingCount, 95),
            percentile(packetTimes, timingCount, 99),
            packetMax,
            receiveOverlapEnabled ? "true" : "false",
            (unsigned long long)receivePrefetchPackets,
            (unsigned long long)receivePrefetchAborts,
            primaryPayloadHighWater,
            secondaryPayloadHighWater,
            receivePrefetchPackets
                ? receivePrefetchWaitTotalMS /
                    (double)receivePrefetchPackets
                : 0.0,
            receivePrefetchWaitMaxMS,
            percentile(completionGaps, gapCount, 50),
            percentile(completionGaps, gapCount, 95),
            percentile(completionGaps, gapCount, 99),
            renderer_histogram_percentile(stats.raw_copy_time_histogram, 99),
            renderer_histogram_percentile(stats.submit_time_histogram, 99),
            renderer_histogram_percentile(stats.gpu_time_histogram, 99),
            tb_native_metal_color_space_name(renderer),
            (unsigned long long)dpcmUploadAllocations,
            (unsigned long long)dpcmDecodedAllocations,
            (unsigned long long)dpcmTextureViewCreations,
            (double)stats.dpcm_upload_capacity_bytes / (1024.0 * 1024.0),
            (double)stats.dpcm_decoded_capacity_bytes / (1024.0 * 1024.0));
        printf(
            "TB_PROTOCOL_METAL metalAllocatedMiB=%.2f "
            "metalAllocatedDeltaMiB=%+.2f metalRecommendedMiB=%.2f\n",
            (double)stats.device_current_allocated_bytes /
                (1024.0 * 1024.0),
            (double)metalAllocatedDeltaBytes / (1024.0 * 1024.0),
            (double)stats.device_recommended_working_set_bytes /
                (1024.0 * 1024.0));
        fflush(stdout);
        receiver_diagnostic(
            ok ? OS_LOG_TYPE_DEFAULT : OS_LOG_TYPE_ERROR,
            "session=%s reason=%s socketErrno=%d packetLength=%u "
            "packetType=0x%02x received=%u dpcm=%u malformed=%u "
            "queueDrops=%u gpuDrops=%llu "
            "rendererFailures=%u fps=%.3f payloadGbps=%.3f "
            "presented=%llu presentationDrops=%llu presentedFPS=%.3f "
            "presentationDrainTimedOut=%s presentationInvariant=%s "
            "presentCallbacksOutOfOrder=%llu presentGapP95MS=%.3f "
            "presentGapP99MS=%.3f presentGapMaxMS=%.3f "
            "receiveOverlap=%s prefetchPackets=%llu prefetchAborts=%llu "
            "primaryPayloadHighWater=%zu secondaryPayloadHighWater=%zu "
            "prefetchWaitAvgMS=%.3f prefetchWaitMaxMS=%.3f "
            "dpcmUploadAllocs=%llu dpcmDecodedAllocs=%llu "
            "dpcmTextureViews=%llu dpcmUploadMiB=%.2f dpcmDecodedMiB=%.2f",
            ok ? "ended" : "failed",
            tb_shutdown_gate_is_requested(shutdownGate)
                ? "shutdown-requested" : sessionEndReason,
            sessionEndErrno,
            sessionEndPacketLength,
            sessionEndPacketType,
            receivedFrames,
            dpcmFrames,
            malformedFrames,
            queueDrops,
            (unsigned long long)droppedFrames,
            rendererFailures,
            actualFPS,
            elapsed > 0.0
                ? (double)payloadBytes * 8.0 / elapsed / 1e9
                : 0.0,
            (unsigned long long)presentedFrames,
            (unsigned long long)presentationDroppedFrames,
            presentedFPS,
            presentationDrainTimedOut ? "true" : "false",
            presentationInvariantViolation ? "failed" : "ok",
            (unsigned long long)
                stats.presentation_epoch_out_of_order_callbacks,
            renderer_histogram_percentile(
                stats.presentation_epoch_gap_histogram, 95),
            renderer_histogram_percentile(
                stats.presentation_epoch_gap_histogram, 99),
            stats.presentation_epoch_gap_ms_max,
            receiveOverlapEnabled ? "true" : "false",
            (unsigned long long)receivePrefetchPackets,
            (unsigned long long)receivePrefetchAborts,
            primaryPayloadHighWater,
            secondaryPayloadHighWater,
            receivePrefetchPackets
                ? receivePrefetchWaitTotalMS /
                    (double)receivePrefetchPackets
                : 0.0,
            receivePrefetchWaitMaxMS,
            (unsigned long long)dpcmUploadAllocations,
            (unsigned long long)dpcmDecodedAllocations,
            (unsigned long long)dpcmTextureViewCreations,
            (double)stats.dpcm_upload_capacity_bytes / (1024.0 * 1024.0),
            (double)stats.dpcm_decoded_capacity_bytes / (1024.0 * 1024.0));
        receiver_diagnostic(
            OS_LOG_TYPE_DEFAULT,
            "session=metal-memory allocatedMiB=%.2f deltaMiB=%+.2f "
            "recommendedMiB=%.2f",
            (double)stats.device_current_allocated_bytes /
                (1024.0 * 1024.0),
            (double)metalAllocatedDeltaBytes / (1024.0 * 1024.0),
            (double)stats.device_recommended_working_set_bytes /
                (1024.0 * 1024.0));

        tb_shutdown_gate_close_peer(shutdownGate, &peer);
        dispatch_sync(dispatch_get_main_queue(), ^{
            presentationController.streamActive = NO;
            (void)restore_global_cursor(
                selectedDisplayID,
                &localCursorHidden,
                "session=ended");
            surfaceView.suppressLocalCursor = NO;
        });
        // Keep the panel awake until the process-global cursor hide has been
        // balanced. If Core Graphics rejects Show, retain the flag so the
        // final cleanup (or the next disconnect) retries the restore.
        tb_power_lifecycle_end_session(&powerLifecycle);
        exitCode = processFatal ? 76 : (ok ? 0 : 2);
        if (tb_shutdown_gate_is_requested(shutdownGate)) break;
        if (serveForever && processFatal) break;
        if (serveForever) {
            // The sender may disconnect because the cable was unplugged, the
            // MacBook slept, or the user stopped the display. Keep the iMac app
            // alive and return to its waiting surface for the next connection.
            if (sessionRejected) {
                showIdleState(@"Stream rejected · waiting to retry",
                              @"Check the sender, then reconnect the cable.");
            } else if (peerReadTimedOut) {
                showIdleState(@"Connection paused · waiting to reconnect",
                              @"The display will resume automatically.");
            } else {
                showIdleState(@"Connection interrupted · waiting to reconnect",
                              @"The display will resume automatically.");
            }
        }
        }
        } while (serveForever &&
                 !tb_shutdown_gate_is_requested(shutdownGate));
        }

        });

        /* Stop AppKit only after the transport group has fully unwound. This
         * makes the old unbounded post-run group wait unnecessary and ensures
         * every dispatch_sync back to main remains serviceable during cleanup. */
        dispatch_group_notify(transportGroup, dispatch_get_main_queue(), ^{
            [NSApp stop:nil];
            NSEvent *wakeEvent = [NSEvent
                otherEventWithType:NSEventTypeApplicationDefined
                location:NSZeroPoint
                modifierFlags:0
                timestamp:0
                windowNumber:0
                context:nil
                subtype:0
                data1:0
                data2:0];
            [NSApp postEvent:wakeEvent atStart:NO];
        });

        [NSApp run];
        /* The group notification normally stops AppKit only after completion.
         * If some unrelated AppKit stop ever returns the run loop early, pump
         * main in short slices so worker dispatch_sync cleanup can still run,
         * but keep one absolute two-second deadline. */
        const CFTimeInterval transportDrainDeadline =
            CACurrentMediaTime() + 2.0;
        while (dispatch_group_wait(transportGroup, DISPATCH_TIME_NOW) != 0 &&
               CACurrentMediaTime() < transportDrainDeadline) {
            [[NSRunLoop currentRunLoop]
                runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        if (dispatch_group_wait(transportGroup, DISPATCH_TIME_NOW) != 0) {
            surfaceView.suppressLocalCursor = NO;
            if (localCursorHidden) {
                (void)restore_global_cursor(
                    selectedDisplayID,
                    &localCursorHidden,
                    "transport-drain-timeout");
            }
            receiver_diagnostic(
                OS_LOG_TYPE_FAULT,
                "shutdown=failed reason=transport-drain-timeout "
                "localCursor=restore-attempted power=release-on-process-exit");
            /* Do not free renderer, buffers, Bonjour, gate, or power state
             * still reachable by the worker. macOS releases process-scoped
             * assertions and descriptors on this fail-fast path. */
            _exit(79);
        }

        if (localCursorHidden) {
            (void)restore_global_cursor(
                selectedDisplayID,
                &localCursorHidden,
                "shutdown");
        }
        surfaceView.suppressLocalCursor = NO;
        presentationController.streamActive = NO;

        const int requestedSignal =
            tb_shutdown_gate_requested_signal(shutdownGate);
        dispatch_source_cancel(sigtermSource);
        dispatch_source_cancel(sigintSource);
        tb_shutdown_gate_close_listener(shutdownGate, &listener);
        [bonjour invalidate];
        bonjour = nil;
        tb_power_lifecycle_stop(&powerLifecycle);
        free(completionGaps);
        free(packetTimes);
        free(payloadSecondary);
        free(payload);
        tb_native_metal_destroy(renderer);
        [presentationController invalidate];
        pthread_mutex_destroy(&lifecycleSnapshot->lock);
        free(lifecycleSnapshot);
        NSApp.delegate = nil;
        [window close];
        if (requestedSignal != 0) {
            receiver_diagnostic(
                localCursorHidden ? OS_LOG_TYPE_ERROR : OS_LOG_TYPE_DEFAULT,
                "shutdown=complete signal=%d localCursor=%s "
                "power=released metal=teardown-complete",
                requestedSignal,
                localCursorHidden ? "restore-failed" : "restored");
        }
        /* The canceled dispatch sources can still have a coalesced main-queue
         * event. Intentionally retain shutdownGate (one mutex + two pipe fds)
         * for the remaining instructions; process exit releases it safely. */
        signal(SIGTERM, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        return exitCode;
    }
}
