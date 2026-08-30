#import "raw_nv12.h"
#import "tb_dpcm.h"
#import "tb_native_metal_renderer.h"
#import "tb_power_lifecycle.h"
#import "tb_pre_session.h"
#import "tb_shutdown_gate.h"

#import <AppKit/AppKit.h>
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
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

enum {
    TB_PACKET_DISPLAY_PROFILE = 0x11,
    TB_PACKET_VIDEO_PARAMETERS = 0x20,
    TB_PACKET_VIDEO_FRAME = 0x21,
    TB_PACKET_RAW_FRAME = 0x22,
    TB_PACKET_DPCM_FRAME = 0x25,
    TB_MAX_PACKET_LENGTH = TB_PRE_SESSION_MAX_PACKET_LENGTH,
    TB_SERVE_PEER_IDLE_TIMEOUT_SECONDS = 15
};

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
        if (received == 0) return false;
        cursor += (size_t)received;
        length -= (size_t)received;
    }
    return true;
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
        if (!activationPolicySet) {
            // Ventura may reject the Regular transform for a diagnostic app
            // launched from an SSH-controlled Aqua session. Accessory still
            // owns visible windows and is sufficient for a display appliance.
            activationPolicySet =
                [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        }
        fprintf(stderr,
                "TB_PROTOCOL_METAL activationPolicy=%ld requestedPolicySet=%s\n",
                (long)NSApp.activationPolicy,
                activationPolicySet ? "true" : "false");
        // This benchmark supplies its own main() instead of NSApplicationMain,
        // so it must explicitly complete the AppKit launch lifecycle before it
        // asks LaunchServices to activate and order a physical window.
        [NSApp finishLaunching];

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
        if (tb_power_lifecycle_start(&powerLifecycle) != 0 ||
            tb_power_lifecycle_begin_session(&powerLifecycle) != 0) {
            tb_power_lifecycle_stop(&powerLifecycle);
            fprintf(stderr,
                    "TB_PROTOCOL_METAL result=failed "
                    "reason=startup-power-lifecycle\n");
            return 72;
        }
        CGDirectDisplayID selectedDisplayID = kCGNullDirectDisplay;
        NSScreen *screen = nil;
        const CFTimeInterval panelWakeDeadline =
            CACurrentMediaTime() + 8.0;
        do {
            screen = native_builtin_5k_screen(&selectedDisplayID);
            if (screen) break;
            [[NSRunLoop currentRunLoop]
                runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        } while (CACurrentMediaTime() < panelWakeDeadline);
        /* Waiting should follow the user's ordinary display-sleep preference.
         * A real accepted session reacquires these two panel assertions. */
        tb_power_lifecycle_end_session(&powerLifecycle);
        if (!screen || !MTLCreateSystemDefaultDevice()) {
            fprintf(stderr,
                    "TB_PROTOCOL_METAL result=failed "
                    "reason=no-active-builtin-native-5k-panel\n");
            tb_power_lifecycle_stop(&powerLifecycle);
            return 69;
        }
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:screen.frame
                      styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered
                          defer:NO
                         screen:screen];
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
        [NSApp activateIgnoringOtherApps:YES];
        [window makeKeyAndOrderFront:nil];
        [window orderFrontRegardless];
        [[NSRunLoop currentRunLoop]
            runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];

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
        uint8_t *payload = (uint8_t *)malloc(TB_MAX_PACKET_LENGTH - 1);
        // Persistent appliance mode retains only the first ten minutes of
        // timing samples. Frame transport itself stays unbounded, while
        // diagnostic memory remains fixed and small.
        const uint32_t timingCapacity = serveForever ? 36000 : expectedFrames;
        double *packetTimes = (double *)calloc(
            (size_t)timingCapacity, sizeof(*packetTimes));
        double *completionGaps = (double *)calloc(
            (size_t)timingCapacity, sizeof(*completionGaps));
        if (!renderer || !payload || !packetTimes || !completionGaps) {
            fprintf(stderr, "TB_PROTOCOL_METAL result=failed reason=allocation\n");
            free(completionGaps);
            free(packetTimes);
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
                [window makeKeyAndOrderFront:nil];
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
            free(payload);
            tb_native_metal_destroy(renderer);
            [window close];
            tb_power_lifecycle_stop(&powerLifecycle);
            signal(SIGTERM, SIG_DFL);
            signal(SIGINT, SIG_DFL);
            return 78;
        }
        const bool supportsDPCM = tb_native_metal_supports_dpcm(renderer) != 0;
        TBBonjourPublisher *bonjour = [[TBBonjourPublisher alloc]
            initWithPort:(uint16_t)portValue supportsDPCM:supportsDPCM];
        if (serveForever) {
            printf("TB_PROTOCOL_METAL state=listening port=%d mode=serve boundedBufferMiB=64 timingWindowFrames=%u\n",
                   portValue, timingCapacity);
        } else {
            printf("TB_PROTOCOL_METAL state=listening port=%d expectedFrames=%u boundedBufferMiB=64\n",
                   portValue, expectedFrames);
        }
        fflush(stdout);
        receiver_diagnostic(
            OS_LOG_TYPE_DEFAULT,
            "state=listening port=%d mode=%s dpcm=%s boundedBufferMiB=64",
            portValue,
            serveForever ? "serve" : "bounded",
            supportsDPCM ? "true" : "false");
        __block int exitCode = 0;
        __block bool localCursorHidden = false;
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
            free(payload);
            tb_native_metal_destroy(renderer);
            [window close];
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
        if (tb_power_lifecycle_begin_session(&powerLifecycle) != 0) {
            tb_shutdown_gate_close_peer(shutdownGate, &peer);
            if (tb_shutdown_gate_is_requested(shutdownGate)) break;
            if (serveForever) {
                showIdleState(@"Couldn’t wake the display · retrying",
                              @"The receiver will try again automatically.");
                continue;
            }
            exitCode = 74;
            break;
        }
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
        const uint64_t sessionPresentationEpoch =
            beginCoveredPresentation();
        if (sessionPresentationEpoch == 0) {
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
            if (!tb_shutdown_gate_is_requested(shutdownGate) &&
                !localCursorHidden) {
                const CGError cursorResult =
                    CGDisplayHideCursor(selectedDisplayID);
                if (cursorResult == kCGErrorSuccess) {
                    localCursorHidden = true;
                    receiver_diagnostic(
                        OS_LOG_TYPE_DEFAULT,
                        "session=active localCursor=hidden display=%u",
                        (unsigned int)selectedDisplayID);
                } else {
                    receiver_diagnostic(
                        OS_LOG_TYPE_ERROR,
                        "session=active localCursor=hide-failed error=%d",
                        (int)cursorResult);
                }
            }
        });
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
        bool liveSurfaceShown = false;
        bool peerReadTimedOut = false;

        while (attemptedFrames < expectedFrames &&
               !tb_shutdown_gate_is_requested(shutdownGate)) {
            @autoreleasepool {
            struct tb_native_metal_stats liveStats;
            tb_native_metal_get_stats(renderer, &liveStats);
            if (!liveSurfaceShown &&
                liveStats.last_presented_epoch >= sessionPresentationEpoch) {
                showLiveSurface();
                liveSurfaceShown = true;
                receiver_diagnostic(
                    OS_LOG_TYPE_DEFAULT,
                    "session=presented epoch=%llu presented=%llu",
                    (unsigned long long)sessionPresentationEpoch,
                    (unsigned long long)liveStats.presented_frames);
            }
            if (liveStats.gpu_error_frames >
                sessionBaseline.gpu_error_frames) {
                rendererFailures++;
                processFatal = true;
                break;
            }
            uint8_t lengthBytes[4];
            errno = 0;
            if (!read_exact(peer, lengthBytes, sizeof(lengthBytes))) {
                peerReadTimedOut = errno == EAGAIN || errno == EWOULDBLOCK;
                break;
            }
            const uint32_t packetLength = load_be32(lengthBytes);
            if (packetLength < 1 || packetLength > TB_MAX_PACKET_LENGTH) {
                fprintf(stderr,
                        "TB_PROTOCOL_METAL error=invalid-packet-length value=%u\n",
                        packetLength);
                break;
            }
            uint8_t packetType = 0;
            errno = 0;
            if (!read_exact(peer, &packetType, 1)) {
                peerReadTimedOut = errno == EAGAIN || errno == EWOULDBLOCK;
                break;
            }
            const size_t payloadLength = (size_t)packetLength - 1;
            const double packetStarted = CACurrentMediaTime();
            errno = 0;
            if (payloadLength > 0 &&
                !read_exact(peer, payload, payloadLength)) {
                peerReadTimedOut = errno == EAGAIN || errno == EWOULDBLOCK;
                break;
            }
            const double completed = CACurrentMediaTime();

            if (packetType == TB_PACKET_VIDEO_PARAMETERS ||
                packetType == TB_PACKET_VIDEO_FRAME) {
                fprintf(stderr,
                        "TB_PROTOCOL_METAL error=unsupported-encoded-video "
                        "packetType=0x%02x; lossless DPCM/RAW required\n",
                        packetType);
                sessionRejected = true;
                break;
            }
            if (packetType != TB_PACKET_RAW_FRAME &&
                packetType != TB_PACKET_DPCM_FRAME) {
                ignoredPackets++;
                continue;
            }
            attemptedFrames++;

            struct tb_raw_nv12_view frame;
            memset(&frame, 0, sizeof(frame));
            __block int renderResult = -1;
            if (packetType == TB_PACKET_RAW_FRAME) {
                if (!tb_raw_nv12_parse(payload, payloadLength, &frame) ||
                    frame.width != 5120 || frame.height != 2880) {
                    malformedRawFrames++;
                    fprintf(stderr,
                            "TB_PROTOCOL_METAL error=malformed-raw-frame payload=%zu\n",
                            payloadLength);
                    sessionRejected = true;
                    break;
                }
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
                struct tb_dpcm_info dpcm;
                if (!supportsDPCM ||
                    tb_dpcm_parse(payload, payloadLength, &dpcm) != 0 ||
                    dpcm.width != 5120 || dpcm.height != 2880 ||
                    dpcm.ten_bit || !dpcm.alpha_omitted) {
                    malformedDPCMFrames++;
                    fprintf(stderr,
                            "TB_PROTOCOL_METAL error=malformed-or-unsupported-dpcm-frame payload=%zu\n",
                            payloadLength);
                    sessionRejected = true;
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
                        break;
                    }
                }
                dispatch_sync(dispatch_get_main_queue(), ^{
                    renderResult = tb_native_metal_render_dpcm(
                        renderer, payload, payloadLength,
                        0, 0, dpcm.width, dpcm.height, 0, 0, 0);
                    [CATransaction flush];
                });
            }
            if (renderResult == 0) {
                queueDrops++;
                if (packetType == TB_PACKET_DPCM_FRAME) {
                    sessionRejected = true;
                    break;
                }
                continue;
            }
            if (renderResult == TB_NATIVE_METAL_RENDER_TRANSIENT_RETRY) {
                sessionRejected = true;
                break;
            }
            if (renderResult < 0) {
                rendererFailures++;
                processFatal = true;
                break;
            }

            const double packetMilliseconds =
                (completed - packetStarted) * 1000.0;
            if (receivedFrames == 0) firstCompletion = completed;
            if (previousCompletion > 0.0 &&
                receivedFrames > 0 && receivedFrames <= timingCapacity) {
                completionGaps[receivedFrames - 1] =
                    (completed - previousCompletion) * 1000.0;
            }
            previousCompletion = completed;
            lastCompletion = completed;
            if (receivedFrames < timingCapacity) {
                packetTimes[receivedFrames] = packetMilliseconds;
            }
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

            tb_native_metal_get_stats(renderer, &liveStats);
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
                break;
            }
            }
        }

        struct tb_native_metal_stats stats;
        const CFTimeInterval deadline = CACurrentMediaTime() + 3.0;
        do {
            tb_native_metal_get_stats(renderer, &stats);
            if (stats.completed_frames >= stats.submitted_frames) break;
            usleep(5000);
        } while (CACurrentMediaTime() < deadline);
        tb_native_metal_get_stats(renderer, &stats);
        if (!liveSurfaceShown &&
            stats.last_presented_epoch >= sessionPresentationEpoch) {
            showLiveSurface();
            liveSurfaceShown = true;
            receiver_diagnostic(
                OS_LOG_TYPE_DEFAULT,
                "session=presented epoch=%llu presented=%llu",
                (unsigned long long)sessionPresentationEpoch,
                (unsigned long long)stats.presented_frames);
        }

        const uint64_t submittedFrames =
            stats.submitted_frames - sessionBaseline.submitted_frames;
        const uint64_t completedFrames =
            stats.completed_frames - sessionBaseline.completed_frames;
        const uint64_t gpuErrorFrames =
            stats.gpu_error_frames - sessionBaseline.gpu_error_frames;
        const uint64_t droppedFrames =
            stats.dropped_frames - sessionBaseline.dropped_frames;
        const uint64_t dpcmUploadAllocations =
            stats.dpcm_upload_buffer_allocations -
            sessionBaseline.dpcm_upload_buffer_allocations;
        const uint64_t dpcmDecodedAllocations =
            stats.dpcm_decoded_buffer_allocations -
            sessionBaseline.dpcm_decoded_buffer_allocations;
        const uint64_t dpcmTextureViewCreations =
            stats.dpcm_texture_view_creations -
            sessionBaseline.dpcm_texture_view_creations;
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
        if (gpuErrorFrames > 0 && !processFatal) {
            rendererFailures++;
            processFatal = true;
        }
        if (completedFrames != submittedFrames && !processFatal) {
            rendererFailures++;
            processFatal = true;
            fprintf(stderr,
                    "TB_PROTOCOL_METAL error=gpu-completion-timeout "
                    "submitted=%llu completed=%llu\n",
                    (unsigned long long)submittedFrames,
                    (unsigned long long)completedFrames);
        }

        const uint32_t timingCount = receivedFrames < timingCapacity
            ? receivedFrames : timingCapacity;
        const uint32_t gapCount = timingCount > 1 ? timingCount - 1 : 0;
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
                        gpuErrorFrames == 0 &&
                        droppedFrames == 0 &&
                        completedFrames == submittedFrames;
        printf(
            "TB_PROTOCOL_METAL result=%s attempted=%u received=%u raw=%u dpcm=%u "
            "ignored=%u malformed=%u malformedRaw=%u malformedDPCM=%u "
            "queueDrops=%u rendererFailures=%u "
            "peerIdleTimeout=%s sessionRejected=%s processFatal=%s "
            "actualFPS=%.3f payloadGbps=%.3f submitted=%llu completed=%llu "
            "gpuErrors=%llu dropped=%llu inflightMax=%llu "
            "lumaMin=%u lumaMax=%u brightSamples=%.2f%% packetReadAvg=%.3fms "
            "packetReadP50=%.3fms packetReadP95=%.3fms "
            "packetReadP99=%.3fms packetReadMax=%.3fms "
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
        fflush(stdout);
        receiver_diagnostic(
            ok ? OS_LOG_TYPE_DEFAULT : OS_LOG_TYPE_ERROR,
            "session=%s received=%u dpcm=%u malformed=%u "
            "queueDrops=%u gpuDrops=%llu "
            "rendererFailures=%u fps=%.3f payloadGbps=%.3f "
            "dpcmUploadAllocs=%llu dpcmDecodedAllocs=%llu "
            "dpcmTextureViews=%llu dpcmUploadMiB=%.2f dpcmDecodedMiB=%.2f",
            ok ? "ended" : "failed",
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
            (unsigned long long)dpcmUploadAllocations,
            (unsigned long long)dpcmDecodedAllocations,
            (unsigned long long)dpcmTextureViewCreations,
            (double)stats.dpcm_upload_capacity_bytes / (1024.0 * 1024.0),
            (double)stats.dpcm_decoded_capacity_bytes / (1024.0 * 1024.0));

        tb_shutdown_gate_close_peer(shutdownGate, &peer);
        dispatch_sync(dispatch_get_main_queue(), ^{
            if (localCursorHidden) {
                const CGError cursorResult =
                    CGDisplayShowCursor(selectedDisplayID);
                if (cursorResult == kCGErrorSuccess) {
                    localCursorHidden = false;
                    receiver_diagnostic(
                        OS_LOG_TYPE_DEFAULT,
                        "session=ended localCursor=restored display=%u",
                        (unsigned int)selectedDisplayID);
                } else {
                    receiver_diagnostic(
                        OS_LOG_TYPE_ERROR,
                        "session=ended localCursor=restore-failed error=%d",
                        (int)cursorResult);
                }
            }
        });
        // Keep the panel awake until the display-specific cursor hide has been
        // balanced. If the display is reconfiguring, retain the flag so the
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
            if (localCursorHidden) {
                (void)CGDisplayShowCursor(selectedDisplayID);
                localCursorHidden = false;
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
            const CGError cursorResult = CGDisplayShowCursor(selectedDisplayID);
            if (cursorResult == kCGErrorSuccess) {
                localCursorHidden = false;
                receiver_diagnostic(
                    OS_LOG_TYPE_DEFAULT,
                    "shutdown localCursor=restored display=%u",
                    (unsigned int)selectedDisplayID);
            } else {
                receiver_diagnostic(
                    OS_LOG_TYPE_ERROR,
                    "shutdown localCursor=restore-failed error=%d",
                    (int)cursorResult);
            }
        }

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
        free(payload);
        tb_native_metal_destroy(renderer);
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
