#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>

#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static const NSInteger TBDefaultDurationSeconds = 60;
// Long enough for the one-hour release soak, while still guaranteeing that an
// unattended diagnostic exits on its own and never writes captured frames.
static const NSInteger TBMaximumDurationSeconds = 3600;

static NSScreen *TBExactRetinaTargetScreen(CGDirectDisplayID requestedDisplayID) {
    const CGDirectDisplayID mainDisplay = CGMainDisplayID();
    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
        if (!number) continue;
        const CGDirectDisplayID displayID = number.unsignedIntValue;
        const NSSize points = screen.frame.size;
        const BOOL identityMatches = requestedDisplayID != 0
            ? displayID == requestedDisplayID
            : [screen.localizedName hasPrefix:@"TB Extend"];
        if (identityMatches &&
            displayID != mainDisplay &&
            fabs(points.width - 2560.0) < 0.5 &&
            fabs(points.height - 1440.0) < 0.5 &&
            fabs(screen.backingScaleFactor - 2.0) < 0.01 &&
            CGDisplayPixelsWide(displayID) == 5120 &&
            CGDisplayPixelsHigh(displayID) == 2880) {
            return screen;
        }
    }
    return nil;
}

@interface TBRetinaMotionView : NSView
@property(nonatomic) NSUInteger tick;
@end

@implementation TBRetinaMotionView

- (BOOL)isOpaque {
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    const CGFloat scale = MAX(1.0, self.window.backingScaleFactor);
    const CGFloat physicalPixel = 1.0 / scale;
    const NSRect bounds = self.bounds;
    const CGFloat phase = (CGFloat)(self.tick % 32) * physicalPixel;

    [[NSColor colorWithCalibratedWhite:0.96 alpha:1.0] setFill];
    NSRectFill(bounds);

    // Full-screen one-physical-pixel grid. Translating it by one backing pixel
    // per tick makes the capture deliver continuously without random data or
    // writing frame artifacts to disk.
    CGContextSaveGState(context);
    CGContextSetShouldAntialias(context, false);
    CGContextSetRGBFillColor(context, 0.08, 0.08, 0.08, 1.0);
    for (CGFloat x = -32.0 + phase; x < NSMaxX(bounds); x += 16.0) {
        CGContextFillRect(context,
                          CGRectMake(x, NSMinY(bounds), physicalPixel,
                                     NSHeight(bounds)));
    }
    for (CGFloat y = -32.0 + phase; y < NSMaxY(bounds); y += 16.0) {
        CGContextFillRect(context,
                          CGRectMake(NSMinX(bounds), y, NSWidth(bounds),
                                     physicalPixel));
    }

    // Moving black/white bars exercise fine contrast edges. The colored bars
    // preserve full-resolution chroma evidence for the lossless 4:4:4 path.
    const CGFloat barTop = NSMaxY(bounds) - 260.0;
    const NSArray<NSColor *> *colors = @[
        NSColor.redColor, NSColor.greenColor, NSColor.blueColor,
        NSColor.cyanColor, NSColor.magentaColor, NSColor.yellowColor,
        NSColor.blackColor, NSColor.whiteColor
    ];
    const CGFloat colorWidth = NSWidth(bounds) / (CGFloat)colors.count;
    for (NSUInteger index = 0; index < colors.count; index++) {
        [colors[index] setFill];
        NSRectFill(NSMakeRect((CGFloat)index * colorWidth,
                              barTop, colorWidth + physicalPixel, 180.0));
    }
    for (NSInteger index = -2; index < 82; index++) {
        const CGFloat x = (CGFloat)index * 32.0 + phase * 2.0;
        [(index & 1) ? NSColor.blackColor : NSColor.whiteColor setFill];
        NSRectFill(NSMakeRect(x, 0.0, 32.0, 96.0));
    }
    CGContextRestoreGState(context);

    NSDictionary<NSAttributedStringKey, id> *titleAttributes = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:42.0
                                                       weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.blackColor,
        NSBackgroundColorAttributeName:
            [NSColor colorWithCalibratedWhite:1.0 alpha:0.82]
    };
    NSDictionary<NSAttributedStringKey, id> *bodyAttributes = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:20.0
                                                       weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: NSColor.blackColor,
        NSBackgroundColorAttributeName:
            [NSColor colorWithCalibratedWhite:1.0 alpha:0.82]
    };
    [@"TargetBridge native Retina motion test" drawAtPoint:NSMakePoint(72.0, 220.0)
                                             withAttributes:titleAttributes];
    NSString *detail = [NSString stringWithFormat:
        @"2560 × 1440 points → 5120 × 2880 pixels | tick %lu\n"
         "Fine text: Il1 0O rn m 0123456789  RGB 4:4:4  P3",
        (unsigned long)self.tick];
    [detail drawAtPoint:NSMakePoint(72.0, 160.0) withAttributes:bodyAttributes];
}

@end

@interface TBRetinaMotionDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic) NSInteger durationSeconds;
@property(nonatomic) CGDirectDisplayID requestedDisplayID;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) TBRetinaMotionView *motionView;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic) CFTimeInterval started;
@property(nonatomic) NSUInteger submittedTicks;
@end

@implementation TBRetinaMotionDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    NSScreen *screen = TBExactRetinaTargetScreen(self.requestedDisplayID);
    if (!screen) {
        fprintf(stderr,
                "TB_RETINA_MOTION result=failed "
                "reason=targetbridge-retina-target-absent requestedDisplay=%u\n",
                (unsigned int)self.requestedDisplayID);
        fflush(stderr);
        // This standalone diagnostic owns no stream, socket, or output file at
        // this point. Exit with a real failure code so an unattended release
        // soak cannot mistake a missing/mis-selected target for success.
        exit(69);
    }

    NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
    const CGDirectDisplayID displayID = number.unsignedIntValue;
    const CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
    const double refresh = mode ? CGDisplayModeGetRefreshRate(mode) : 0.0;
    if (mode) CGDisplayModeRelease(mode);
    printf("TB_RETINA_MOTION state=selected display=%u name=%s "
           "points=2560x1440 pixels=5120x2880 scale=2 refresh=%.3fHz "
           "duration=%lds\n",
           (unsigned int)displayID, screen.localizedName.UTF8String,
           refresh, (long)self.durationSeconds);
    fflush(stdout);

    self.motionView = [[TBRetinaMotionView alloc] initWithFrame:screen.frame];
    self.window = [[NSWindow alloc]
        initWithContentRect:screen.frame
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:NO
                     screen:screen];
    self.window.opaque = YES;
    self.window.backgroundColor = NSColor.blackColor;
    self.window.hasShadow = NO;
    self.window.collectionBehavior =
        NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.window.contentView = self.motionView;
    [self.window setFrame:screen.frame display:YES];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    self.started = CACurrentMediaTime();
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 60.0)
                                                 repeats:YES
                                                   block:^(NSTimer *timer) {
        (void)timer;
        TBRetinaMotionDelegate *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.submittedTicks++;
        strongSelf.motionView.tick = strongSelf.submittedTicks;
        [strongSelf.motionView setNeedsDisplay:YES];
        if (CACurrentMediaTime() - strongSelf.started >=
            (CFTimeInterval)strongSelf.durationSeconds) {
            [strongSelf finish];
        }
    }];
    self.timer.tolerance = 0.0;
}

- (void)finish {
    [self.timer invalidate];
    self.timer = nil;
    const CFTimeInterval elapsed = CACurrentMediaTime() - self.started;
    const double tickRate = elapsed > 0.0
        ? (double)self.submittedTicks / elapsed : 0.0;
    printf("TB_RETINA_MOTION result=ok submittedTicks=%lu elapsed=%.3fs "
           "tickRate=%.3fHz filesWritten=0\n",
           (unsigned long)self.submittedTicks, elapsed, tickRate);
    fflush(stdout);
    [self.window orderOut:nil];
    [NSApp terminate:nil];
}

@end

static BOOL TBParseArguments(int argc, const char *argv[],
                             NSInteger *durationSeconds,
                             CGDirectDisplayID *requestedDisplayID) {
    if (argc > 3 || !durationSeconds || !requestedDisplayID) return NO;
    *requestedDisplayID = 0;
    if (argc == 1) {
        *durationSeconds = TBDefaultDurationSeconds;
        return YES;
    }
    errno = 0;
    char *end = NULL;
    const long parsed = strtol(argv[1], &end, 10);
    if (errno != 0 || end == argv[1] || *end != '\0' ||
        parsed < 1 || parsed > TBMaximumDurationSeconds) {
        return NO;
    }
    *durationSeconds = (NSInteger)parsed;
    if (argc == 3) {
        errno = 0;
        end = NULL;
        const unsigned long display = strtoul(argv[2], &end, 10);
        if (errno != 0 || end == argv[2] || *end != '\0' ||
            display == 0 || display > UINT32_MAX) {
            return NO;
        }
        *requestedDisplayID = (CGDirectDisplayID)display;
    }
    return YES;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSInteger durationSeconds = 0;
        CGDirectDisplayID requestedDisplayID = 0;
        if (!TBParseArguments(argc, argv, &durationSeconds,
                              &requestedDisplayID)) {
            fprintf(stderr,
                    "usage: %s [duration-seconds:1..%ld] [display-id]\n",
                    argv[0], (long)TBMaximumDurationSeconds);
            return 64;
        }
        NSApplication *application = NSApplication.sharedApplication;
        application.activationPolicy = NSApplicationActivationPolicyAccessory;
        TBRetinaMotionDelegate *delegate = [[TBRetinaMotionDelegate alloc] init];
        delegate.durationSeconds = durationSeconds;
        delegate.requestedDisplayID = requestedDisplayID;
        application.delegate = delegate;
        [application run];
        return 0;
    }
}
