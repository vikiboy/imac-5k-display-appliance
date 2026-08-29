#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

#import "../TargetBridgeSupport/TargetBridge-Bridging-Header.h"

static void print_mode(const char *label, CGDirectDisplayID displayID) {
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
    if (!mode) {
        printf("TB_HIDPI_PROBE %s mode=missing\n", label);
        return;
    }
    printf("TB_HIDPI_PROBE %s points=%zux%zu pixels=%zux%zu refresh=%.2f flags=0x%x\n",
           label,
           CGDisplayModeGetWidth(mode),
           CGDisplayModeGetHeight(mode),
           CGDisplayModeGetPixelWidth(mode),
           CGDisplayModeGetPixelHeight(mode),
           CGDisplayModeGetRefreshRate(mode),
           CGDisplayModeGetIOFlags(mode));
    CGDisplayModeRelease(mode);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        /* CGVirtualDisplayMode dimensions are logical points when hiDPI is on.
         * The correct 27-inch Retina construction is therefore 2560x1440 here,
         * which WindowServer backs with 5120x2880 pixels. Passing 5120x2880 is a
         * useful negative control, but it is not the native 2x construction. */
        const NSUInteger requestedWidth = argc > 1 ? strtoul(argv[1], NULL, 10) : 2560;
        const NSUInteger requestedHeight = argc > 2 ? strtoul(argv[2], NULL, 10) : 1440;

        CGVirtualDisplayDescriptor *descriptor = [CGVirtualDisplayDescriptor new];
        descriptor.name = @"TargetBridge HiDPI Construction Probe";
        descriptor.vendorID = 0xEEEF;
        descriptor.productID = 0x7001;
        descriptor.serialNum = 0x20260829;
        descriptor.serialNumber = 0x20260829;
        descriptor.maxPixelsWide = 5120;
        descriptor.maxPixelsHigh = 2880;
        descriptor.sizeInMillimeters = CGSizeMake(597, 336);

        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
        CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
        settings.hiDPI = YES;
        settings.modes = @[[[CGVirtualDisplayMode alloc]
            initWithWidth:requestedWidth height:requestedHeight refreshRate:60.0]];

        if (!display || ![display applySettings:settings]) {
            fprintf(stderr, "TB_HIDPI_PROBE result=failed requested=%zux%zu\n",
                    requestedWidth, requestedHeight);
            return 1;
        }
        printf("TB_HIDPI_PROBE result=created requested=%zux%zu displayID=%u\n",
               requestedWidth, requestedHeight, display.displayID);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
        print_mode("initial", display.displayID);

        NSDictionary *options = @{
            (__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES
        };
        NSArray *modes = CFBridgingRelease(CGDisplayCopyAllDisplayModes(
            display.displayID, (__bridge CFDictionaryRef)options));
        CGDisplayModeRef retinaMode = NULL;
        for (id candidateObject in modes) {
            CGDisplayModeRef candidate = (__bridge CGDisplayModeRef)candidateObject;
            if (CGDisplayModeGetWidth(candidate) == 2560 &&
                CGDisplayModeGetHeight(candidate) == 1440 &&
                CGDisplayModeGetPixelWidth(candidate) == 5120 &&
                CGDisplayModeGetPixelHeight(candidate) == 2880) {
                retinaMode = candidate;
                break;
            }
        }
        if (!retinaMode) {
            printf("TB_HIDPI_PROBE retina-mode=missing\n");
            return 2;
        }
        CGError setError = CGDisplaySetDisplayMode(display.displayID, retinaMode, NULL);
        printf("TB_HIDPI_PROBE retina-set-error=%d\n", setError);
        print_mode("immediate", display.displayID);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
        print_mode("settled", display.displayID);
    }
    return 0;
}
