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
        NSView *metalPlaceholder = [[NSView alloc] initWithFrame:view.bounds];
        metalPlaceholder.autoresizingMask =
            NSViewWidthSizable | NSViewHeightSizable;
        [view addSubview:metalPlaceholder];
        window.contentView = view;
        [window makeKeyAndOrderFront:nil];
        view.suppressLocalCursor = YES;
        [window invalidateCursorRectsForView:view];
        [view resetCursorRects];
        [view updateTrackingAreas];
        [view reapplyCursorPolicy];
        if (!view.suppressLocalCursor || view.window != window ||
            metalPlaceholder.superview != view ||
            !NSEqualRects(metalPlaceholder.frame, view.bounds) ||
            view.trackingAreas.count == 0 ||
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
        printf("cursor shield view test passed (key window, child surface, transparent rect lifecycle)\n");
        return 0;
    }
}
