#import "tb_cursor_shield_view.h"

#include <string.h>

@implementation TBCursorShieldView {
    NSCursor *_transparentCursor;
    NSTrackingArea *_cursorTrackingArea;
    BOOL _appKitCursorHidden;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (!self) return nil;

    NSBitmapImageRep *transparentBitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                    pixelsWide:16
                    pixelsHigh:16
                 bitsPerSample:8
               samplesPerPixel:4
                      hasAlpha:YES
                      isPlanar:NO
                colorSpaceName:NSCalibratedRGBColorSpace
                   bytesPerRow:0
                  bitsPerPixel:0];
    if (!transparentBitmap) return nil;
    memset(transparentBitmap.bitmapData,
           0,
           (size_t)transparentBitmap.bytesPerRow *
               (size_t)transparentBitmap.pixelsHigh);
    NSImage *transparentImage =
        [[NSImage alloc] initWithSize:NSMakeSize(16.0, 16.0)];
    [transparentImage addRepresentation:transparentBitmap];
    _transparentCursor = [[NSCursor alloc]
        initWithImage:transparentImage
              hotSpot:NSZeroPoint];
    if (!_transparentCursor) return nil;
    return self;
}

- (void)setSuppressLocalCursor:(BOOL)suppressLocalCursor {
    if (_suppressLocalCursor == suppressLocalCursor) return;
    _suppressLocalCursor = suppressLocalCursor;
    [self.window invalidateCursorRectsForView:self];
    [self reapplyCursorPolicy];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    self.window.acceptsMouseMovedEvents = YES;
    [self reapplyCursorPolicy];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_cursorTrackingArea) {
        [self removeTrackingArea:_cursorTrackingArea];
    }
    _cursorTrackingArea = [[NSTrackingArea alloc]
        initWithRect:self.bounds
             options:NSTrackingCursorUpdate |
                     NSTrackingActiveInKeyWindow |
                     NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:_cursorTrackingArea];
}

- (void)cursorUpdate:(NSEvent *)event {
    (void)event;
    [self reapplyCursorPolicy];
}

- (void)resetCursorRects {
    if (_suppressLocalCursor && NSApp.isActive && self.window.isKeyWindow) {
        [self addCursorRect:self.bounds cursor:_transparentCursor];
    }
}

- (void)reapplyCursorPolicy {
    const BOOL shouldHide =
        _suppressLocalCursor && NSApp.isActive && self.window.isKeyWindow;
    if (shouldHide) {
        /* App activation, wake, and key-window changes can each reset the
         * effective cursor even while our balanced hide remains owned.
         * Reassert it with a net-zero unhide/hide pair before installing the
         * transparent window cursor again. */
        if (!_appKitCursorHidden) {
            [NSCursor hide];
            _appKitCursorHidden = YES;
        } else {
            [NSCursor unhide];
            [NSCursor hide];
        }
        [_transparentCursor set];
    } else if (_appKitCursorHidden) {
        [NSCursor unhide];
        _appKitCursorHidden = NO;
    } else if (!_suppressLocalCursor && NSApp.isActive) {
        [NSCursor.arrowCursor set];
    }
}

- (void)dealloc {
    if (_appKitCursorHidden) {
        [NSCursor unhide];
    }
}

@end
