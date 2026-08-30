#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

int main(void) {
    @autoreleasepool {
        NSDictionary *session = CFBridgingRelease(
            CGSessionCopyCurrentDictionary());
        NSLog(@"session=%@", session ?: @{});

        NSRunningApplication *frontmost =
            NSWorkspace.sharedWorkspace.frontmostApplication;
        NSLog(@"frontmost name=%@ bundle=%@ pid=%d active=%@",
              frontmost.localizedName ?: @"",
              frontmost.bundleIdentifier ?: @"",
              frontmost.processIdentifier,
              NSApp.isActive ? @"true" : @"false");

        uint32_t displayCount = 0;
        if (CGGetOnlineDisplayList(0, NULL, &displayCount) == kCGErrorSuccess &&
            displayCount > 0) {
            CGDirectDisplayID displays[32] = {0};
            displayCount = MIN(displayCount, 32u);
            if (CGGetOnlineDisplayList(
                    displayCount, displays, &displayCount) == kCGErrorSuccess) {
                for (uint32_t index = 0; index < displayCount; index++) {
                    NSLog(@"display=%u active=%d asleep=%d online=%d",
                          displays[index],
                          CGDisplayIsActive(displays[index]),
                          CGDisplayIsAsleep(displays[index]),
                          CGDisplayIsOnline(displays[index]));
                }
            }
        }

        NSArray<NSDictionary *> *windows = CFBridgingRelease(
            CGWindowListCopyWindowInfo(
                kCGWindowListOptionOnScreenOnly |
                    kCGWindowListExcludeDesktopElements,
                kCGNullWindowID));
        for (NSDictionary *window in windows ?: @[]) {
            NSLog(@"window owner=%@ pid=%@ layer=%@ alpha=%@ name=%@ bounds=%@",
                  window[(NSString *)kCGWindowOwnerName] ?: @"",
                  window[(NSString *)kCGWindowOwnerPID] ?: @0,
                  window[(NSString *)kCGWindowLayer] ?: @0,
                  window[(NSString *)kCGWindowAlpha] ?: @0,
                  window[(NSString *)kCGWindowName] ?: @"",
                  window[(NSString *)kCGWindowBounds] ?: @{});
        }
    }
    return 0;
}
