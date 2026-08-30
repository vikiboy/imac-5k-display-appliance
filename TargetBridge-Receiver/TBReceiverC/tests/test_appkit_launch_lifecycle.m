#import <AppKit/AppKit.h>

@interface TBTestApplianceWindow : NSWindow
@end

@implementation TBTestApplianceWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@interface TBLaunchLifecycleDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic) NSUInteger didFinishLaunchingCount;
@end

@implementation TBLaunchLifecycleDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.didFinishLaunchingCount++;
    dispatch_async(dispatch_get_main_queue(), ^{
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
}

@end

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        TBLaunchLifecycleDelegate *delegate =
            [[TBLaunchLifecycleDelegate alloc] init];
        NSApp.delegate = delegate;

        TBTestApplianceWindow *window = [[TBTestApplianceWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 320, 180)
                      styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered
                          defer:NO];
        if (!window.canBecomeKeyWindow || !window.canBecomeMainWindow) {
            fprintf(stderr,
                    "FAIL appkit_launch_lifecycle borderless appliance cannot become key/main\n");
            return 1;
        }

        NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@""];
        NSMenuItem *appMenuItem = [[NSMenuItem alloc]
            initWithTitle:@"iMac 5K Display Appliance"
                   action:nil
            keyEquivalent:@""];
        NSMenu *appMenu = [[NSMenu alloc]
            initWithTitle:@"iMac 5K Display Appliance"];
        [appMenu addItemWithTitle:@"About"
                          action:@selector(orderFrontStandardAboutPanel:)
                   keyEquivalent:@""];
        appMenuItem.submenu = appMenu;
        [mainMenu addItem:appMenuItem];
        NSApp.mainMenu = mainMenu;

        [NSApp run];

        if (delegate.didFinishLaunchingCount != 1) {
            fprintf(stderr,
                    "FAIL appkit_launch_lifecycle didFinishLaunching=%lu\n",
                    (unsigned long)delegate.didFinishLaunchingCount);
            return 1;
        }

        printf("PASS appkit_launch_lifecycle didFinishLaunching=1\n");
        return 0;
    }
}
