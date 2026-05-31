#import "VirtualDisplayBridge.h"

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(size_t)width
                       height:(size_t)height
                  refreshRate:(double)refreshRate;
@property(nonatomic, readonly) size_t width;
@property(nonatomic, readonly) size_t height;
@property(nonatomic, readonly) double refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic, copy) NSArray<CGVirtualDisplayMode *> *modes;
@property(nonatomic) CGVirtualDisplayMode *mode;
@property(nonatomic) BOOL hiDPI;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) size_t maxPixelsWide;
@property(nonatomic) size_t maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@end

static void MDCopyError(const char *message, char *errorBuffer, size_t errorBufferSize) {
    if (errorBuffer == NULL || errorBufferSize == 0) {
        return;
    }

    if (message == NULL) {
        message = "Unknown virtual display error.";
    }

    snprintf(errorBuffer, errorBufferSize, "%s", message);
}

bool MDVirtualDisplayAPIAvailable(void) {
    return NSClassFromString(@"CGVirtualDisplay") != nil &&
           NSClassFromString(@"CGVirtualDisplayDescriptor") != nil &&
           NSClassFromString(@"CGVirtualDisplayMode") != nil &&
           NSClassFromString(@"CGVirtualDisplaySettings") != nil;
}

bool MDVirtualDisplayCreate(
    const char *name,
    uint32_t framebufferWidth,
    uint32_t framebufferHeight,
    uint32_t refreshRate,
    bool hiDPI,
    uint32_t serialNumber,
    MDVirtualDisplayHandle *outHandle,
    uint32_t *outDisplayID,
    char *errorBuffer,
    size_t errorBufferSize
) {
    if (outHandle == NULL || outDisplayID == NULL) {
        MDCopyError("Invalid output pointers.", errorBuffer, errorBufferSize);
        return false;
    }

    *outHandle = NULL;
    *outDisplayID = 0;

    if (!MDVirtualDisplayAPIAvailable()) {
        MDCopyError("CGVirtualDisplay is not available on this macOS version.", errorBuffer, errorBufferSize);
        return false;
    }

    if (framebufferWidth < 640 || framebufferHeight < 360) {
        MDCopyError("Virtual display framebuffer is too small.", errorBuffer, errorBufferSize);
        return false;
    }

    @autoreleasepool {
        NSString *displayName = name != NULL ? [NSString stringWithUTF8String:name] : nil;
        if (displayName.length == 0) {
            displayName = @"MacDisplay Virtual HiDPI";
        }

        size_t logicalWidth = hiDPI ? MAX((size_t)320, (size_t)framebufferWidth / 2) : framebufferWidth;
        size_t logicalHeight = hiDPI ? MAX((size_t)180, (size_t)framebufferHeight / 2) : framebufferHeight;

        CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
        descriptor.name = displayName;
        descriptor.vendorID = 0x4d44;
        descriptor.productID = 0x0001;
        descriptor.serialNum = serialNumber == 0 ? 1 : serialNumber;
        descriptor.maxPixelsWide = framebufferWidth;
        descriptor.maxPixelsHigh = framebufferHeight;
        descriptor.sizeInMillimeters = CGSizeMake(700, 390);

        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
        if (display == nil) {
            MDCopyError("Could not create CGVirtualDisplay.", errorBuffer, errorBufferSize);
            return false;
        }

        CGVirtualDisplayMode *mode = [[CGVirtualDisplayMode alloc] initWithWidth:logicalWidth
                                                                          height:logicalHeight
                                                                     refreshRate:refreshRate == 0 ? 60.0 : refreshRate];
        CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
        settings.modes = @[mode];
        settings.mode = mode;
        settings.hiDPI = hiDPI;

        if (![display applySettings:settings]) {
            MDCopyError("macOS rejected the virtual display settings.", errorBuffer, errorBufferSize);
            return false;
        }

        *outDisplayID = display.displayID;
        *outHandle = (__bridge_retained void *)display;
        return true;
    }
}

void MDVirtualDisplayRelease(MDVirtualDisplayHandle handle) {
    if (handle == NULL) {
        return;
    }

    CFRelease(handle);
}
