#ifndef TB_CURSOR_SHIELD_VIEW_H
#define TB_CURSOR_SHIELD_VIEW_H

#import <AppKit/AppKit.h>

/* Window-scoped visual cursor suppression. The presentation controller owns
 * wake/session/key-window observation and calls reapplyCursorPolicy after it
 * has restored the appliance window to the active AppKit cursor context. */
@interface TBCursorShieldView : NSView
@property(nonatomic) BOOL suppressLocalCursor;
- (void)reapplyCursorPolicy;
@end

#endif
