#import "tb_cursor_shield_view.h"

#import <AppKit/AppKit.h>

#include <stdio.h>

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        TBCursorShieldView *view = [[TBCursorShieldView alloc]
            initWithFrame:NSMakeRect(0.0, 0.0, 512.0, 288.0)];
        if (!view) {
            fprintf(stderr, "cursor shield view test: construction failed\n");
            return 1;
        }
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(-1000.0, -1000.0, 512.0, 288.0)
                      styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered
                          defer:NO];
        /* Match the appliance window's ARC ownership. NSWindow otherwise
         * self-releases on close, which double-releases a strong ARC local. */
        window.releasedWhenClosed = NO;
        NSView *metalPlaceholder = [[NSView alloc] initWithFrame:view.bounds];
        metalPlaceholder.autoresizingMask =
            NSViewWidthSizable | NSViewHeightSizable;
        [view addSubview:metalPlaceholder];
        window.contentView = view;
        /* Do not make a CI runner's real window/cursor globally active. The
         * physical key-window path is covered by the source contract and the
         * hardware acceptance matrix; this unit test proves that a non-key
         * appliance retains window-scoped suppression intent without taking a
         * process-global cursor hide. */
        view.suppressLocalCursor = YES;
        [window invalidateCursorRectsForView:view];
        [view resetCursorRects];
        [view updateTrackingAreas];
        [view reapplyCursorPolicy];
        NSTrackingArea *trackingArea = view.trackingAreas.firstObject;
        if (!view.suppressLocalCursor || view.window != window ||
            metalPlaceholder.superview != view ||
            !NSEqualRects(metalPlaceholder.frame, view.bounds) ||
            !trackingArea ||
            !(trackingArea.options & NSTrackingActiveAlways) ||
            (trackingArea.options & NSTrackingActiveInKeyWindow) ||
            !window.acceptsMouseMovedEvents) {
            fprintf(stderr,
                    "cursor shield view test: window/hierarchy enable failed\n");
            return 1;
        }
        view.suppressLocalCursor = NO;
        [view reapplyCursorPolicy];
        if (view.suppressLocalCursor) {
            fprintf(stderr, "cursor shield view test: release failed\n");
            return 1;
        }
        [window close];
        printf("cursor shield view test passed (non-key suppression intent, child surface, transparent rect lifecycle)\n");
        return 0;
    }
}
