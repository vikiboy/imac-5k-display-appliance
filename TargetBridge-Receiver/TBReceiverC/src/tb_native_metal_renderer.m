#import "tb_native_metal_renderer.h"
#import "tb_dpcm.h"

#import <AppKit/AppKit.h>
#import <CoreVideo/CoreVideo.h>
#import <dispatch/dispatch.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <os/lock.h>
#import <simd/simd.h>

#include <stdio.h>
#include <string.h>

static size_t tb_native_metal_timing_bucket(double milliseconds) {
    if (milliseconds <= 0.0) return 0;
    size_t bucket = (size_t)(milliseconds / TB_NATIVE_METAL_TIMING_BUCKET_MS);
    return bucket < TB_NATIVE_METAL_TIMING_BUCKETS
        ? bucket
        : TB_NATIVE_METAL_TIMING_BUCKETS - 1;
}

#define TB_NATIVE_METAL_TEARDOWN_TIMEOUT_NSEC (2ull * NSEC_PER_SEC)

@interface TBNativeMetalView : NSView
@end

@implementation TBNativeMetalView

- (CALayer *)makeBackingLayer {
    return [CAMetalLayer layer];
}

- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    /* SDL's content view remains the sole input target. */
    return nil;
}

- (BOOL)acceptsFirstResponder {
    return NO;
}

@end

typedef struct {
    vector_float2 drawableSize;
    vector_float2 cursorPosition;
    vector_float2 cursorSize;
    uint32_t cursorVisible;
    uint32_t cursorType;
    uint32_t fullRange;
    uint32_t cursorLarge;
} TBNativeMetalUniforms;

/* Must remain byte-for-byte layout-compatible with DpcmParams in the Metal
 * source below. Offsets are into the already validated TBD2 upload buffer. */
typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t tilesX;
    uint32_t tilesY;
    uint32_t tileCount;
    uint32_t outStridePx;
    uint32_t widthOff;
    uint32_t seedOff;
    uint32_t payOff;
    uint32_t bits;
    uint32_t alpha;
} TBNativeMetalDPCMParams;

static const char TBNativeMetalShader[] = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct RasterData {
    float4 position [[position]];
    float2 texCoord;
};

struct Uniforms {
    float2 drawableSize;
    float2 cursorPosition;
    float2 cursorSize;
    uint cursorVisible;
    uint cursorType;
    uint fullRange;
    uint cursorLarge;
};

vertex RasterData tbVideoVertex(uint vertexID [[vertex_id]]) {
    constexpr float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    constexpr float2 texCoords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    RasterData out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

static bool tbArrowMask(float2 p, float expansion) {
    const bool head = p.x >= -expansion &&
                      p.y >= -expansion &&
                      p.y <= 31.0 + expansion &&
                      p.x <= p.y * 0.61 + 2.0 + expansion;
    const bool stem = p.x >= 7.0 - expansion &&
                      p.x <= 14.0 + expansion &&
                      p.y >= 21.0 - expansion &&
                      p.y <= 41.0 + expansion;
    return head || stem;
}

fragment float4 tbVideoFragment(RasterData in [[stage_in]],
                                texture2d<float, access::sample> luma [[texture(0)]],
                                texture2d<float, access::sample> chroma [[texture(1)]],
                                constant Uniforms &uniforms [[buffer(0)]]) {
    constexpr sampler linearSampler(coord::normalized,
                                    address::clamp_to_edge,
                                    filter::linear);
    float y = luma.sample(linearSampler, in.texCoord).r;
    float2 uv = chroma.sample(linearSampler, in.texCoord).rg;

    if (uniforms.fullRange == 0) {
        y = max(0.0, (y - (16.0 / 255.0)) * (255.0 / 219.0));
        uv = (uv - 0.5) * (255.0 / 224.0);
    } else {
        uv -= 0.5;
    }

    float3 rgb;
    rgb.r = y + 1.5748 * uv.y;
    rgb.g = y - 0.1873 * uv.x - 0.4681 * uv.y;
    rgb.b = y + 1.8556 * uv.x;
    rgb = clamp(rgb, 0.0, 1.0);

    if (uniforms.cursorVisible != 0) {
        float2 scale = max(uniforms.cursorSize / float2(24.0, 42.0), float2(0.01));
        float2 cursorPoint = (in.position.xy - uniforms.cursorPosition) / scale;
        /* Match the normal macOS-style overlay used by the OpenGL path:
         * white outline with a dark body. */
        if (tbArrowMask(cursorPoint, 1.7)) rgb = float3(0.98);
        if (tbArrowMask(cursorPoint, 0.0)) rgb = float3(0.03);
    }

    return float4(rgb, 1.0);
}

fragment float4 tbPackedBGRAFragment(
                                RasterData in [[stage_in]],
                                texture2d<float, access::sample> packed [[texture(0)]],
                                constant Uniforms &uniforms [[buffer(0)]]) {
    constexpr sampler nearestSampler(coord::normalized,
                                     address::clamp_to_edge,
                                     filter::nearest);
    float3 rgb = packed.sample(nearestSampler, in.texCoord).rgb;
    if (uniforms.cursorVisible != 0) {
        float2 scale = max(uniforms.cursorSize / float2(24.0, 42.0), float2(0.01));
        float2 cursorPoint = (in.position.xy - uniforms.cursorPosition) / scale;
        if (tbArrowMask(cursorPoint, 1.7)) rgb = float3(0.98);
        if (tbArrowMask(cursorPoint, 0.0)) rgb = float3(0.03);
    }
    return float4(rgb, 1.0);
}

#if TB_ENABLE_DPCM
/* Audited whole-frame TBD2 decoder. One 64-thread group decodes one independent
 * 8x8 tile. tb_dpcm_parse re-derives and validates every plane and group offset
 * before this bounds-check-free kernel sees a blob. */
struct DpcmParams {
    uint width, height, tilesX, tilesY, tileCount, outStridePx;
    uint widthOff, seedOff, payOff;
    uint bits, alpha;
};

static inline uint tb_width_get(device const uchar *plane, uint idx) {
    uchar b = plane[idx >> 1];
    return (idx & 1u) ? uint(b >> 4) : uint(b & 0xF);
}

static inline uint tb_bits_at(device const uchar *buf, uint p, uint n) {
    if (n == 0u) return 0u;
    uint byte = p >> 3, sh = p & 7u;
    uint x = uint(buf[byte]);
    if (sh + n > 8u) x |= uint(buf[byte + 1]) << 8;
    if (sh + n > 16u) x |= uint(buf[byte + 2]) << 16;
    return (x >> sh) & ((1u << n) - 1u);
}

static inline int tb_unzig(uint z) {
    return int((z >> 1) ^ (~(z & 1u) + 1u));
}

kernel void tb_dpcm_decode(device const uchar *blob [[buffer(0)]],
                           device const uint *gtab [[buffer(1)]],
                           device uint *out [[buffer(2)]],
                           constant DpcmParams &P [[buffer(3)]],
                           uint tile [[threadgroup_position_in_grid]],
                           uint lane [[thread_position_in_threadgroup]]) {
    device const uchar *wp = blob + P.widthOff;
    device const uint *seeds = (device const uint *)(blob + P.seedOff);
    device const uchar *pay = blob + P.payOff;
    const uint grp = tile / 64u, idx = tile % 64u;

    uint jcost = 0u;
    {
        const uint jt = grp * 64u + lane;
        if (lane < idx && jt < P.tileCount) {
            const uint jx = jt % P.tilesX, jy = jt / P.tilesX;
            const uint jw = min(8u, P.width - jx * 8u);
            const uint jh = min(8u, P.height - jy * 8u);
            const uint jn = tb_width_get(wp, jt * 3u + 0u)
                          + tb_width_get(wp, jt * 3u + 1u)
                          + tb_width_get(wp, jt * 3u + 2u);
            jcost = jn * (jw * jh - 1u);
        }
    }
    threadgroup uint red[64];
    red[lane] = jcost;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint off = 32u; off > 0u; off >>= 1) {
        if (lane < off) red[lane] += red[lane + off];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    const uint x = lane & 7u, y = lane >> 3;
    const uint txi = tile % P.tilesX, tyi = tile / P.tilesX;
    const uint tw = min(8u, P.width - txi * 8u);
    const uint th = min(8u, P.height - tyi * 8u);
    const uint coded = tw * th - 1u;
    const bool live = (x < tw && y < th);

    const uint n0 = tb_width_get(wp, tile * 3u + 0u);
    const uint n1 = tb_width_get(wp, tile * 3u + 1u);
    const uint n2 = tb_width_get(wp, tile * 3u + 2u);
    const uint b0 = gtab[grp] + red[0];
    const uint b1 = b0 + n0 * coded;
    const uint b2 = b1 + n1 * coded;

    int3 d = int3(0);
    if (live && !(x == 0u && y == 0u)) {
        const uint k = y * tw + x - 1u;
        d.x = tb_unzig(tb_bits_at(pay, b0 + k * n0, n0));
        d.y = tb_unzig(tb_bits_at(pay, b1 + k * n1, n1));
        d.z = tb_unzig(tb_bits_at(pay, b2 + k * n2, n2));
    }

    threadgroup int3 rowd[64];
    threadgroup int3 cold[8];
    rowd[lane] = (x == 0u) ? int3(0) : d;
    if (x == 0u) cold[y] = (y == 0u) ? int3(0) : d;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (!live) return;

    int3 acc = int3(0);
    for (uint j = 1u; j <= y; ++j) acc += cold[j];
    for (uint i = 1u; i <= x; ++i) acc += rowd[y * 8u + i];

    const uint mask = (1u << P.bits) - 1u;
    const uint sraw = seeds[tile];
    const int3 seed = int3(int((sraw >> (0u * P.bits)) & mask),
                           int((sraw >> (1u * P.bits)) & mask),
                           int((sraw >> (2u * P.bits)) & mask));
    const uint3 v = uint3(seed + acc) & mask;
    out[(tyi * 8u + y) * P.outStridePx + (txi * 8u + x)] =
        P.alpha | v.x | (v.y << P.bits) | (v.z << (2u * P.bits));
}
#endif
)METAL";

static BOOL tb_pixel_buffer_uses_display_p3(CVPixelBufferRef pixelBuffer) {
    if (!pixelBuffer) return NO;
    if (@available(macOS 12.0, *)) {
        CFTypeRef primaries = CVBufferCopyAttachment(
            pixelBuffer, kCVImageBufferColorPrimariesKey, NULL);
        const BOOL isDisplayP3 =
            primaries && CFGetTypeID(primaries) == CFStringGetTypeID() &&
            CFEqual(primaries, kCVImageBufferColorPrimaries_P3_D65);
        if (primaries) CFRelease(primaries);
        return isDisplayP3;
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        CFTypeRef primaries = CVBufferGetAttachment(
            pixelBuffer, kCVImageBufferColorPrimariesKey, NULL);
        const BOOL isDisplayP3 =
            primaries && CFGetTypeID(primaries) == CFStringGetTypeID() &&
            CFEqual(primaries, kCVImageBufferColorPrimaries_P3_D65);
#pragma clang diagnostic pop
        return isDisplayP3;
    }
}

int tb_native_metal_dpcm_dimensions_supported(int width, int height) {
    if (width <= 0 || height <= 0) return 0;
    const size_t pixelWidth = (size_t)width;
    const size_t pixelHeight = (size_t)height;
    if (pixelWidth > SIZE_MAX / 4) return 0;
    const size_t tightBytesPerRow = pixelWidth * 4;
    return pixelHeight <=
        TB_NATIVE_METAL_MAX_DPCM_DECODED_BYTES / tightBytesPerRow;
}

size_t tb_native_metal_dpcm_next_upload_capacity(size_t current,
                                                  size_t required,
                                                  size_t limit) {
    if (required == 0 || limit == 0 || required > limit) return 0;
    if (current >= required) return current <= limit ? current : 0;

    /* The first allocation is right-sized. Later record highs grow by 1.5x,
     * which prevents slightly larger compressed frames from allocating and
     * retiring another shared Metal buffer every time. */
    size_t capacity = current ? current : required;
    while (capacity < required) {
        size_t growth = capacity / 2;
        if (growth == 0) growth = 1;
        if (growth > limit - capacity) {
            capacity = limit;
            break;
        }
        capacity += growth;
    }
    return capacity >= required ? capacity : 0;
}

@interface TBNativeMetalRenderer : NSObject
- (instancetype)initRenderer;
- (void)setVisible:(BOOL)visible;
- (uint64_t)beginPresentationSession;
- (int)renderPixelBuffer:(CVPixelBufferRef)pixelBuffer
                 cursorX:(int)cursorX
                 cursorY:(int)cursorY
             cursorWidth:(int)cursorWidth
            cursorHeight:(int)cursorHeight
           cursorVisible:(BOOL)cursorVisible
              cursorType:(int)cursorType
             cursorLarge:(BOOL)cursorLarge
           rememberFrame:(BOOL)rememberFrame;
- (int)renderNV12PlanesY:(const uint8_t *)y
                 yStride:(int)yStride
                      uv:(const uint8_t *)uv
                uvStride:(int)uvStride
                   width:(int)width
                  height:(int)height
                 cursorX:(int)cursorX
                 cursorY:(int)cursorY
             cursorWidth:(int)cursorWidth
            cursorHeight:(int)cursorHeight
           cursorVisible:(BOOL)cursorVisible
              cursorType:(int)cursorType
             cursorLarge:(BOOL)cursorLarge;
- (BOOL)supportsDPCM;
- (int)renderDPCMBlob:(const uint8_t *)blob
               length:(size_t)length
              cursorX:(int)cursorX
              cursorY:(int)cursorY
          cursorWidth:(int)cursorWidth
         cursorHeight:(int)cursorHeight
        cursorVisible:(BOOL)cursorVisible
           cursorType:(int)cursorType
          cursorLarge:(BOOL)cursorLarge;
- (int)renderCursorX:(int)cursorX
             cursorY:(int)cursorY
         cursorWidth:(int)cursorWidth
        cursorHeight:(int)cursorHeight
       cursorVisible:(BOOL)cursorVisible
          cursorType:(int)cursorType
         cursorLarge:(BOOL)cursorLarge;
- (void)copyStats:(struct tb_native_metal_stats *)stats;
- (const char *)colorSpaceName;
- (BOOL)isRenderAdmissionClosed;
- (BOOL)hasTerminalGPUError;
- (int)claimInflightSlotForRender;
- (void)recordCommandCompletionFailed:(BOOL)gpuFailed
                       gpuMilliseconds:(double)gpuMilliseconds;
- (uint64_t)currentPresentationEpoch;
- (void)recordDrawablePresentedForEpoch:(uint64_t)epoch;
- (BOOL)isTeardownQuarantined;
- (void)beginTeardown;
- (BOOL)waitUntilIdleWithTimeoutNanos:(uint64_t)timeoutNanos;
#if defined(TB_NATIVE_METAL_TESTING)
- (int)testRecordCompletionFailureForPath:(int)completionPath;
- (int)testClaimInflightSlot;
- (int)testReleaseInflightSlot;
#endif
@end

@implementation TBNativeMetalRenderer {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLRenderPipelineState> _packedPipeline;
    id<MTLComputePipelineState> _dpcmPipeline;
    id<MTLBuffer> _dpcmUploads[3];
    size_t _dpcmUploadCapacities[3];
    NSUInteger _dpcmUploadIndex;
    id<MTLBuffer> _dpcmFrame;
    size_t _dpcmFrameCapacity;
    id<MTLTexture> _dpcmFrameTexture;
    id<MTLBuffer> _dpcmFrameTextureBacking;
    size_t _dpcmFrameTextureWidth;
    size_t _dpcmFrameTextureHeight;
    size_t _dpcmFrameTextureBytesPerRow;
    CVMetalTextureCacheRef _textureCache;
    CVPixelBufferPoolRef _rawPool;
    size_t _rawPoolWidth;
    size_t _rawPoolHeight;
    TBNativeMetalView *_view;
    CAMetalLayer *_metalLayer;
    CGColorSpaceRef _layerColorSpace;
    dispatch_semaphore_t _inflightSemaphore;
    CVPixelBufferRef _latestFrame;
    os_unfair_lock _statsLock;
    struct tb_native_metal_stats _stats;
    BOOL _loggedFirstFrame;
    BOOL _displayP3;
    BOOL _teardownQuarantined;
    BOOL _terminalGPUError;
#if defined(TB_NATIVE_METAL_TESTING)
    int _testClaimedSlots;
#endif
}

- (instancetype)initRenderer {
    self = [super init];
    if (!self) return nil;

    _statsLock = OS_UNFAIR_LOCK_INIT;
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) return nil;
    _commandQueue = [_device newCommandQueue];
    if (!_commandQueue) return nil;

    NSError *libraryError = nil;
    NSString *shaderSource = [NSString stringWithUTF8String:TBNativeMetalShader];
    MTLCompileOptions *baseCompileOptions = [[MTLCompileOptions alloc] init];
    baseCompileOptions.preprocessorMacros = @{ @"TB_ENABLE_DPCM": @0 };
    id<MTLLibrary> library = [_device newLibraryWithSource:shaderSource
                                                   options:baseCompileOptions
                                                     error:&libraryError];
    if (!library) {
        fprintf(stderr, "[metal-native] shader compile failed: %s\n",
                libraryError.localizedDescription.UTF8String ?: "unknown error");
        return nil;
    }

    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.label = @"TargetBridge NV12 Pipeline";
    descriptor.vertexFunction = [library newFunctionWithName:@"tbVideoVertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"tbVideoFragment"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

    NSError *pipelineError = nil;
    _pipeline = [_device newRenderPipelineStateWithDescriptor:descriptor error:&pipelineError];
    if (!_pipeline) {
        fprintf(stderr, "[metal-native] pipeline creation failed: %s\n",
                pipelineError.localizedDescription.UTF8String ?: "unknown error");
        return nil;
    }

    MTLRenderPipelineDescriptor *packedDescriptor =
        [[MTLRenderPipelineDescriptor alloc] init];
    packedDescriptor.label = @"TargetBridge Packed BGRA Pipeline";
    packedDescriptor.vertexFunction = [library newFunctionWithName:@"tbVideoVertex"];
    packedDescriptor.fragmentFunction =
        [library newFunctionWithName:@"tbPackedBGRAFragment"];
    packedDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    NSError *packedError = nil;
    _packedPipeline = [_device newRenderPipelineStateWithDescriptor:packedDescriptor
                                                               error:&packedError];
    if (!_packedPipeline) {
        fprintf(stderr, "[metal-native] packed BGRA pipeline unavailable: %s\n",
                packedError.localizedDescription.UTF8String ?: "unknown error");
    }

    NSError *dpcmLibraryError = nil;
    MTLCompileOptions *dpcmCompileOptions = [[MTLCompileOptions alloc] init];
    dpcmCompileOptions.preprocessorMacros = @{ @"TB_ENABLE_DPCM": @1 };
    id<MTLLibrary> dpcmLibrary = [_device newLibraryWithSource:shaderSource
                                                       options:dpcmCompileOptions
                                                         error:&dpcmLibraryError];
    NSError *dpcmError = nil;
    id<MTLFunction> dpcmFunction =
        [dpcmLibrary newFunctionWithName:@"tb_dpcm_decode"];
    if (dpcmLibrary && dpcmFunction) {
        _dpcmPipeline = [_device newComputePipelineStateWithFunction:dpcmFunction
                                                               error:&dpcmError];
    }
    if (!_dpcmPipeline) {
        fprintf(stderr, "[metal-native] TBD2 GPU pipeline unavailable: %s\n",
                dpcmError.localizedDescription.UTF8String ?:
                dpcmLibraryError.localizedDescription.UTF8String ?:
                "shader function missing");
    }

    CVReturn cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault,
                                                      NULL,
                                                      _device,
                                                      NULL,
                                                      &_textureCache);
    if (cacheStatus != kCVReturnSuccess || !_textureCache) {
        fprintf(stderr, "[metal-native] CVMetalTextureCacheCreate failed: %d\n",
                (int)cacheStatus);
        return nil;
    }

    _inflightSemaphore = dispatch_semaphore_create(3);
    fprintf(stderr, "[metal-native] device=%s dpcm=%s\n",
            _device.name.UTF8String ?: "unknown",
            (_dpcmPipeline && _packedPipeline) ? "yes" : "no");
    return self;
}

- (void)dealloc {
    [self setVisible:NO];
    if (_metalLayer) _metalLayer.colorspace = nil;
    if (_layerColorSpace) {
        CGColorSpaceRelease(_layerColorSpace);
        _layerColorSpace = NULL;
    }
    if (_textureCache) {
        CVMetalTextureCacheFlush(_textureCache, 0);
        CFRelease(_textureCache);
        _textureCache = NULL;
    }
    if (_rawPool) {
        CVPixelBufferPoolFlush(_rawPool, kCVPixelBufferPoolFlushExcessBuffers);
        CFRelease(_rawPool);
        _rawPool = NULL;
    }
}

- (BOOL)ensureRawPoolWidth:(size_t)width height:(size_t)height {
    if (_rawPool && _rawPoolWidth == width && _rawPoolHeight == height) return YES;
    if (_rawPool) {
        CVPixelBufferPoolFlush(_rawPool, kCVPixelBufferPoolFlushExcessBuffers);
        CFRelease(_rawPool);
        _rawPool = NULL;
    }

    NSDictionary *poolAttributes = @{
        (__bridge NSString *)kCVPixelBufferPoolMinimumBufferCountKey: @4
    };
    NSDictionary *pixelAttributes = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (__bridge NSString *)kCVPixelBufferWidthKey: @(width),
        (__bridge NSString *)kCVPixelBufferHeightKey: @(height),
        (__bridge NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    const CVReturn status = CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        (__bridge CFDictionaryRef)poolAttributes,
        (__bridge CFDictionaryRef)pixelAttributes,
        &_rawPool);
    if (status != kCVReturnSuccess || !_rawPool) {
        fprintf(stderr, "[metal-native] raw CVPixelBufferPoolCreate failed: %d\n",
                (int)status);
        return NO;
    }
    _rawPoolWidth = width;
    _rawPoolHeight = height;
    fprintf(stderr, "[metal-native] raw IOSurface pool %zux%zu\n", width, height);
    return YES;
}

- (NSWindow *)receiverWindow {
    NSWindow *best = nil;
    CGFloat bestArea = 0.0;
    for (NSWindow *window in NSApp.windows) {
        if (!window.isVisible) continue;
        const CGFloat area = window.frame.size.width * window.frame.size.height;
        if (area > bestArea) {
            bestArea = area;
            best = window;
        }
    }
    return best;
}

- (BOOL)attachViewIfNeeded {
    if (![NSThread isMainThread]) {
        fprintf(stderr, "[metal-native] UI attachment requested off main thread\n");
        return NO;
    }

    NSWindow *window = [self receiverWindow];
    if (!window) return NO;
    NSView *contentView = window.contentView;
    if (!contentView) return NO;
    if (_view.window == window && _view.superview == contentView && _metalLayer) return YES;

    /* SDL may replace its Cocoa window while entering its fullscreen Space.
     * Follow the largest visible receiver window instead of retaining the
     * initial 980x620 window forever. */
    if (_view) {
        if (_metalLayer) _metalLayer.colorspace = nil;
        if (_layerColorSpace) {
            CGColorSpaceRelease(_layerColorSpace);
            _layerColorSpace = NULL;
        }
        [_view removeFromSuperview];
        _view = nil;
        _metalLayer = nil;
    }

    _view = [[TBNativeMetalView alloc] initWithFrame:contentView.bounds];
    _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _view.wantsLayer = YES;
    _view.hidden = YES;
    [contentView addSubview:_view positioned:NSWindowAbove relativeTo:nil];

    _metalLayer = (CAMetalLayer *)_view.layer;
    if (![_metalLayer isKindOfClass:CAMetalLayer.class]) return NO;
    _metalLayer.device = _device;
    _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (srgb) {
        _metalLayer.colorspace = srgb;
        /* CAMetalLayer's CF-typed property does not declare ownership in the
         * Objective-C header. Retain our own reference until the layer is
         * detached so older macOS releases cannot observe a dangling space. */
        _layerColorSpace = srgb;
    }
    _displayP3 = NO;
    _metalLayer.framebufferOnly = YES;
    _metalLayer.opaque = YES;
    _metalLayer.presentsWithTransaction = NO;
    _metalLayer.allowsNextDrawableTimeout = YES;
    if ([_metalLayer respondsToSelector:@selector(setMaximumDrawableCount:)]) {
        _metalLayer.maximumDrawableCount = 3;
    }
    if ([_metalLayer respondsToSelector:@selector(setDisplaySyncEnabled:)]) {
        _metalLayer.displaySyncEnabled = NO;
    }
    fprintf(stderr,
            "[metal-native] attached window=%ld points=%.0fx%.0f scale=%.1f title=%s\n",
            (long)window.windowNumber,
            contentView.bounds.size.width,
            contentView.bounds.size.height,
            window.backingScaleFactor,
            window.title.UTF8String ?: "");
    return YES;
}

- (void)updateOutputColorSpaceDisplayP3:(BOOL)displayP3 {
    if (!_metalLayer) return;
    if (_metalLayer.colorspace && displayP3 == _displayP3) return;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(
        displayP3 ? kCGColorSpaceDisplayP3 : kCGColorSpaceSRGB);
    if (!colorSpace) return;
    CGColorSpaceRef previousColorSpace = _layerColorSpace;
    _layerColorSpace = colorSpace;
    _metalLayer.colorspace = colorSpace;
    if (previousColorSpace) CGColorSpaceRelease(previousColorSpace);
    _displayP3 = displayP3;
    fprintf(stderr, "[metal-native] output color space = %s\n",
            displayP3 ? "Display P3" : "sRGB");
}

- (void)updateColorSpaceForPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    [self updateOutputColorSpaceDisplayP3:
        tb_pixel_buffer_uses_display_p3(pixelBuffer)];
}

- (void)updateDrawableSize {
    if (!_view || !_metalLayer) return;
    NSRect backingBounds = [_view convertRectToBacking:_view.bounds];
    const CGSize size = CGSizeMake(MAX(1.0, backingBounds.size.width),
                                   MAX(1.0, backingBounds.size.height));
    _metalLayer.contentsScale = _view.window.backingScaleFactor;
    if (!CGSizeEqualToSize(_metalLayer.drawableSize, size)) {
        _metalLayer.drawableSize = size;
        fprintf(stderr, "[metal-native] drawable %.0fx%.0f\n", size.width, size.height);
    }
}

- (void)setVisible:(BOOL)visible {
    @autoreleasepool {
        if (visible) {
            if ([self isRenderAdmissionClosed]) return;
            if ([self attachViewIfNeeded]) {
                [self updateDrawableSize];
                _view.hidden = NO;
            }
            return;
        }

        if (_view) _view.hidden = YES;
        if (_latestFrame) {
            CVPixelBufferRelease(_latestFrame);
            _latestFrame = NULL;
        }
    }
}

- (uint64_t)beginPresentationSession {
    if ([self isRenderAdmissionClosed] || ![self attachViewIfNeeded]) return 0;
    [self updateDrawableSize];
    /* The dedicated receiver keeps an opaque AppKit cover above this view.
     * Leaving Metal drawable avoids nextDrawable starvation on a hidden layer. */
    _view.hidden = NO;
    os_unfair_lock_lock(&_statsLock);
    _stats.presentation_epoch++;
    if (_stats.presentation_epoch == 0) _stats.presentation_epoch++;
    const uint64_t epoch = _stats.presentation_epoch;
    os_unfair_lock_unlock(&_statsLock);
    return epoch;
}

- (void)recordDrop {
    os_unfair_lock_lock(&_statsLock);
    _stats.dropped_frames++;
    os_unfair_lock_unlock(&_statsLock);
}

- (void)recordRawCopyMilliseconds:(double)milliseconds {
    os_unfair_lock_lock(&_statsLock);
    _stats.raw_copy_samples++;
    _stats.raw_copy_time_ms_total += milliseconds;
    _stats.raw_copy_time_histogram[
        tb_native_metal_timing_bucket(milliseconds)]++;
    if (milliseconds > _stats.raw_copy_time_ms_max) {
        _stats.raw_copy_time_ms_max = milliseconds;
    }
    os_unfair_lock_unlock(&_statsLock);
}

/* Return the same values as the public render functions: 1 means this call
 * owns one of the three in-flight slots, 0 is bounded queue pressure, and -1
 * is a permanent renderer failure. Holding the renderer lock across the
 * non-blocking semaphore claim serializes admission with a Metal completion
 * latching the terminal GPU error. */
- (int)claimInflightSlotForRender {
    os_unfair_lock_lock(&_statsLock);
    if (_teardownQuarantined || _terminalGPUError) {
        os_unfair_lock_unlock(&_statsLock);
        return -1;
    }
    if (dispatch_semaphore_wait(_inflightSemaphore, DISPATCH_TIME_NOW) != 0) {
        _stats.dropped_frames++;
        os_unfair_lock_unlock(&_statsLock);
        return 0;
    }
    os_unfair_lock_unlock(&_statsLock);
    return 1;
}

/* Both NV12 presentation and DPCM decode/presentation complete here. A failed
 * submitted command is process-terminal: retaining the latch on the renderer
 * makes every later capability check and render admission fail closed while
 * the completion still releases its ordinary in-flight accounting. */
- (void)recordCommandCompletionFailed:(BOOL)gpuFailed
                       gpuMilliseconds:(double)gpuMilliseconds {
    os_unfair_lock_lock(&_statsLock);
    _stats.completed_frames++;
    if (gpuFailed) {
        _stats.gpu_error_frames++;
        _terminalGPUError = YES;
    }
    if (_stats.inflight_frames > 0) {
        _stats.inflight_frames--;
    }
    _stats.gpu_time_ms_total += gpuMilliseconds;
    _stats.gpu_time_histogram[
        tb_native_metal_timing_bucket(gpuMilliseconds)]++;
    if (gpuMilliseconds > _stats.gpu_time_ms_max) {
        _stats.gpu_time_ms_max = gpuMilliseconds;
    }
    os_unfair_lock_unlock(&_statsLock);
}

- (uint64_t)currentPresentationEpoch {
    os_unfair_lock_lock(&_statsLock);
    const uint64_t epoch = _stats.presentation_epoch;
    os_unfair_lock_unlock(&_statsLock);
    return epoch;
}

- (void)recordDrawablePresentedForEpoch:(uint64_t)epoch {
    os_unfair_lock_lock(&_statsLock);
    _stats.presented_frames++;
    if (epoch > _stats.last_presented_epoch) {
        _stats.last_presented_epoch = epoch;
    }
    os_unfair_lock_unlock(&_statsLock);
}

- (int)renderNV12PlanesY:(const uint8_t *)y
                 yStride:(int)yStride
                      uv:(const uint8_t *)uv
                uvStride:(int)uvStride
                   width:(int)width
                  height:(int)height
                 cursorX:(int)cursorX
                 cursorY:(int)cursorY
             cursorWidth:(int)cursorWidth
            cursorHeight:(int)cursorHeight
           cursorVisible:(BOOL)cursorVisible
             cursorType:(int)cursorType
             cursorLarge:(BOOL)cursorLarge {
    @autoreleasepool {
        if ([self isRenderAdmissionClosed] ||
            !y || !uv || width <= 0 || height <= 0 || (width & 1) ||
            (height & 1) || width > 8192 || height > 8192 ||
            yStride < width || uvStride < width || yStride > 16384 ||
            uvStride > 16384) return -1;
        if (![self ensureRawPoolWidth:(size_t)width height:(size_t)height]) return -1;

        CVPixelBufferRef pixelBuffer = NULL;
        const CFTimeInterval copyStarted = CACurrentMediaTime();
        NSDictionary *auxiliaryAttributes = @{
            (__bridge NSString *)kCVPixelBufferPoolAllocationThresholdKey: @4
        };
        const CVReturn createStatus = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            _rawPool,
            (__bridge CFDictionaryRef)auxiliaryAttributes,
            &pixelBuffer);
        if (createStatus == kCVReturnWouldExceedAllocationThreshold) {
            [self recordDrop];
            return 0;
        }
        if (createStatus != kCVReturnSuccess || !pixelBuffer) {
            fprintf(stderr, "[metal-native] raw pixel buffer allocation failed: %d\n",
                    (int)createStatus);
            return -1;
        }

        const CVReturn lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, 0);
        if (lockStatus != kCVReturnSuccess ||
            CVPixelBufferGetPlaneCount(pixelBuffer) < 2) {
            if (lockStatus == kCVReturnSuccess) {
                CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
            }
            CVPixelBufferRelease(pixelBuffer);
            return -1;
        }

        uint8_t *destinationY = (uint8_t *)
            CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
        uint8_t *destinationUV = (uint8_t *)
            CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
        const size_t destinationYStride =
            CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
        const size_t destinationUVStride =
            CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
        if (!destinationY || !destinationUV ||
            destinationYStride < (size_t)width ||
            destinationUVStride < (size_t)width) {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
            CVPixelBufferRelease(pixelBuffer);
            return -1;
        }
        for (int row = 0; row < height; row++) {
            memcpy(destinationY + (size_t)row * destinationYStride,
                   y + (size_t)row * (size_t)yStride,
                   (size_t)width);
        }
        for (int row = 0; row < height / 2; row++) {
            memcpy(destinationUV + (size_t)row * destinationUVStride,
                   uv + (size_t)row * (size_t)uvStride,
                   (size_t)width);
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        [self recordRawCopyMilliseconds:
            (CACurrentMediaTime() - copyStarted) * 1000.0];

        /* RAW v1 carries no color metadata. Tag the diagnostic conservatively
         * as BT.709/sRGB; a future header must carry actual source metadata
         * before RAW can claim Display-P3 fidelity. */
        CVBufferSetAttachment(pixelBuffer,
                              kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2,
                              kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(pixelBuffer,
                              kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2,
                              kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(pixelBuffer,
                              kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                              kCVAttachmentMode_ShouldPropagate);

        const int result = [self renderPixelBuffer:pixelBuffer
                                           cursorX:cursorX
                                           cursorY:cursorY
                                       cursorWidth:cursorWidth
                                      cursorHeight:cursorHeight
                                     cursorVisible:cursorVisible
                                        cursorType:cursorType
                                       cursorLarge:cursorLarge
                                     rememberFrame:YES];
        CVPixelBufferRelease(pixelBuffer);
        return result;
    }
}

- (int)renderPixelBuffer:(CVPixelBufferRef)pixelBuffer
                 cursorX:(int)cursorX
                 cursorY:(int)cursorY
             cursorWidth:(int)cursorWidth
            cursorHeight:(int)cursorHeight
           cursorVisible:(BOOL)cursorVisible
              cursorType:(int)cursorType
           cursorLarge:(BOOL)cursorLarge
           rememberFrame:(BOOL)rememberFrame {
    @autoreleasepool {
        if ([self isRenderAdmissionClosed] ||
            !pixelBuffer || ![self attachViewIfNeeded]) return -1;
        [self updateDrawableSize];
        [self updateColorSpaceForPixelBuffer:pixelBuffer];
        _view.hidden = NO;

        const int admission = [self claimInflightSlotForRender];
        if (admission <= 0) return admission;
        const CFTimeInterval submitStarted = CACurrentMediaTime();

        const size_t width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0);
        const size_t height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);
        const size_t chromaWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1);
        const size_t chromaHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1);

        CVMetalTextureRef lumaRef = NULL;
        CVMetalTextureRef chromaRef = NULL;
        CVReturn lumaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, _textureCache, pixelBuffer, NULL,
            MTLPixelFormatR8Unorm, width, height, 0, &lumaRef);
        CVReturn chromaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, _textureCache, pixelBuffer, NULL,
            MTLPixelFormatRG8Unorm, chromaWidth, chromaHeight, 1, &chromaRef);
        id<MTLTexture> lumaTexture = lumaRef ? CVMetalTextureGetTexture(lumaRef) : nil;
        id<MTLTexture> chromaTexture = chromaRef ? CVMetalTextureGetTexture(chromaRef) : nil;

        if (lumaStatus != kCVReturnSuccess || chromaStatus != kCVReturnSuccess ||
            !lumaTexture || !chromaTexture) {
            if (lumaRef) CFRelease(lumaRef);
            if (chromaRef) CFRelease(chromaRef);
            dispatch_semaphore_signal(_inflightSemaphore);
            fprintf(stderr, "[metal-native] CVMetalTexture creation failed: %d/%d\n",
                    (int)lumaStatus, (int)chromaStatus);
            return -1;
        }

        const CFTimeInterval drawableStarted = CACurrentMediaTime();
        id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
        const double drawableWaitMS =
            (CACurrentMediaTime() - drawableStarted) * 1000.0;
        os_unfair_lock_lock(&_statsLock);
        _stats.drawable_requests++;
        _stats.drawable_wait_ms_total += drawableWaitMS;
        _stats.drawable_wait_histogram[
            tb_native_metal_timing_bucket(drawableWaitMS)]++;
        if (drawableWaitMS > _stats.drawable_wait_ms_max) {
            _stats.drawable_wait_ms_max = drawableWaitMS;
        }
        os_unfair_lock_unlock(&_statsLock);
        if (!drawable) {
            CFRelease(lumaRef);
            CFRelease(chromaRef);
            dispatch_semaphore_signal(_inflightSemaphore);
            [self recordDrop];
            return 0;
        }

        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

        TBNativeMetalUniforms uniforms;
        memset(&uniforms, 0, sizeof(uniforms));
        const CGSize drawableSize = _metalLayer.drawableSize;
        uniforms.drawableSize = (vector_float2){(float)drawableSize.width,
                                                (float)drawableSize.height};
        const float sourceWidth = (float)MAX(1, cursorWidth);
        const float sourceHeight = (float)MAX(1, cursorHeight);
        uniforms.cursorPosition = (vector_float2){
            (float)cursorX * (float)drawableSize.width / sourceWidth,
            (float)cursorY * (float)drawableSize.height / sourceHeight
        };
        /* Use drawable pixels, not backingScale. Multiplying by Retina scale
         * made the Metal cursor twice the size of the author's OpenGL fix. */
        const float cursorBase = drawableSize.width >= 5000.0
            ? (cursorLarge ? 58.0f : 32.0f)
            : (cursorLarge ? 44.0f : 24.0f);
        uniforms.cursorSize = (vector_float2){cursorBase * 0.75f,
                                              cursorBase * 1.1875f};
        uniforms.cursorVisible = cursorVisible ? 1u : 0u;
        uniforms.cursorType = (uint32_t)MAX(0, cursorType);
        uniforms.cursorLarge = cursorLarge ? 1u : 0u;
        const OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
        uniforms.fullRange =
            format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 1u : 0u;

        id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
        if (!commandBuffer) {
            CFRelease(lumaRef);
            CFRelease(chromaRef);
            dispatch_semaphore_signal(_inflightSemaphore);
            return -1;
        }
        commandBuffer.label = @"TargetBridge NV12 Frame";
        id<MTLRenderCommandEncoder> encoder =
            [commandBuffer renderCommandEncoderWithDescriptor:pass];
        if (!encoder) {
            CFRelease(lumaRef);
            CFRelease(chromaRef);
            dispatch_semaphore_signal(_inflightSemaphore);
            return -1;
        }
        [encoder setRenderPipelineState:_pipeline];
        [encoder setFragmentTexture:lumaTexture atIndex:0];
        [encoder setFragmentTexture:chromaTexture atIndex:1];
        [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [encoder endEncoding];
        const uint64_t presentationEpoch = [self currentPresentationEpoch];
        __weak TBNativeMetalRenderer *weakSelf = self;
        [drawable addPresentedHandler:^(id<MTLDrawable> presentedDrawable) {
            (void)presentedDrawable;
            [weakSelf recordDrawablePresentedForEpoch:presentationEpoch];
        }];
        [commandBuffer presentDrawable:drawable];

        /* A queue/drawable drop must not become visible later through a cursor
         * redraw. Publish latestFrame only after this frame has secured every
         * resource needed for command submission. */
        if (rememberFrame && pixelBuffer != _latestFrame) {
            CVPixelBufferRetain(pixelBuffer);
            if (_latestFrame) CVPixelBufferRelease(_latestFrame);
            _latestFrame = pixelBuffer;
        }

        CVPixelBufferRetain(pixelBuffer);
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            double gpuMS = 0.0;
            if (completed.GPUEndTime > completed.GPUStartTime) {
                gpuMS = (completed.GPUEndTime - completed.GPUStartTime) * 1000.0;
            }
            const BOOL gpuFailed =
                completed.status != MTLCommandBufferStatusCompleted;
            if (gpuFailed) {
                fprintf(stderr,
                        "[metal-native] command buffer failed status=%ld error=%s\n",
                        (long)completed.status,
                        completed.error.localizedDescription.UTF8String ?: "unknown");
            }
            CVPixelBufferRelease(pixelBuffer);
            CFRelease(lumaRef);
            CFRelease(chromaRef);
            /* Publish completion only after all retained frame resources are
             * released. Callers use this counter as a destruction barrier in
             * benchmarks and diagnostics, so incrementing it earlier exposed
             * a narrow use-after-release race at shutdown. */
            [self recordCommandCompletionFailed:gpuFailed
                                gpuMilliseconds:gpuMS];
            dispatch_semaphore_signal(self->_inflightSemaphore);
        }];

        os_unfair_lock_lock(&_statsLock);
        _stats.submitted_frames++;
        _stats.inflight_frames++;
        if (_stats.inflight_frames > _stats.inflight_frames_max) {
            _stats.inflight_frames_max = _stats.inflight_frames;
        }
        os_unfair_lock_unlock(&_statsLock);
        [commandBuffer commit];
        const double submitMS =
            (CACurrentMediaTime() - submitStarted) * 1000.0;
        os_unfair_lock_lock(&_statsLock);
        _stats.submit_samples++;
        _stats.submit_time_ms_total += submitMS;
        _stats.submit_time_histogram[tb_native_metal_timing_bucket(submitMS)]++;
        if (submitMS > _stats.submit_time_ms_max) {
            _stats.submit_time_ms_max = submitMS;
        }
        os_unfair_lock_unlock(&_statsLock);

        if (!_loggedFirstFrame) {
            _loggedFirstFrame = YES;
            fprintf(stderr,
                    "[metal-native] first NV12 frame %zux%zu submitted without CPU upload\n",
                    width, height);
        }
        return 1;
    }
}

- (BOOL)supportsDPCM {
    return ![self isRenderAdmissionClosed] &&
        _dpcmPipeline != nil && _packedPipeline != nil;
}

- (int)renderDPCMBlob:(const uint8_t *)blob
               length:(size_t)length
              cursorX:(int)cursorX
              cursorY:(int)cursorY
          cursorWidth:(int)cursorWidth
         cursorHeight:(int)cursorHeight
        cursorVisible:(BOOL)cursorVisible
           cursorType:(int)cursorType
          cursorLarge:(BOOL)cursorLarge {
    if (!blob || ![self supportsDPCM]) return -1;

    /* Parsing is the trust boundary for the bounds-check-free GPU kernel. The
     * maintained path deliberately stays 8-bit-only until the 10-bit capture,
     * color-management and panel presentation chain is audited end to end. */
    struct tb_dpcm_info info;
    if (tb_dpcm_parse(blob, length, &info) != 0 ||
        !info.alpha_omitted || info.ten_bit ||
        !tb_native_metal_dpcm_dimensions_supported(info.width, info.height) ||
        info.width > 8192 || info.height > 8192 ||
        length > UINT32_MAX ||
        info.group_table_off > UINT32_MAX ||
        info.width_plane_off > UINT32_MAX ||
        info.seed_plane_off > UINT32_MAX ||
        info.payload_off > UINT32_MAX) {
        fprintf(stderr,
                "[metal-native] rejected malformed/unsupported 8-bit TBD2 blob (%zu bytes)\n",
                length);
        return -1;
    }

    @autoreleasepool {
        if (![self attachViewIfNeeded]) {
            return TB_NATIVE_METAL_RENDER_TRANSIENT_RETRY;
        }
        [self updateDrawableSize];
        // Whole-frame TBD2 is an explicit 8-bit SDR Display P3 contract. The
        // blob is RGB-byte-lossless but carries no color metadata of its own.
        [self updateOutputColorSpaceDisplayP3:YES];
        _view.hidden = NO;

        const int admission = [self claimInflightSlotForRender];
        if (admission <= 0) return admission;
        const CFTimeInterval submitStarted = CACurrentMediaTime();

        const NSUInteger uploadSlot = _dpcmUploadIndex;
        if (_dpcmUploadCapacities[uploadSlot] < length) {
            const size_t uploadLimit =
                tb_dpcm_max_size(info.width, info.height);
            const size_t uploadCapacity =
                tb_native_metal_dpcm_next_upload_capacity(
                    _dpcmUploadCapacities[uploadSlot], length, uploadLimit);
            if (uploadCapacity == 0) {
                dispatch_semaphore_signal(_inflightSemaphore);
                return -1;
            }
            _dpcmUploads[uploadSlot] =
                [_device newBufferWithLength:uploadCapacity
                                     options:MTLResourceStorageModeShared];
            _dpcmUploadCapacities[uploadSlot] =
                _dpcmUploads[uploadSlot] ? uploadCapacity : 0;
            if (_dpcmUploads[uploadSlot]) {
                uint64_t totalCapacity = 0;
                for (NSUInteger slot = 0; slot < 3; slot++) {
                    totalCapacity += _dpcmUploadCapacities[slot];
                }
                os_unfair_lock_lock(&_statsLock);
                _stats.dpcm_upload_buffer_allocations++;
                _stats.dpcm_upload_capacity_bytes = totalCapacity;
                os_unfair_lock_unlock(&_statsLock);
            }
        }
        id<MTLBuffer> upload = _dpcmUploads[uploadSlot];
        if (!upload) {
            dispatch_semaphore_signal(_inflightSemaphore);
            return -1;
        }
        memcpy(upload.contents, blob, length);

        NSUInteger alignment =
            [_device minimumLinearTextureAlignmentForPixelFormat:
                MTLPixelFormatBGRA8Unorm];
        if (alignment == 0) alignment = 256;
        const size_t tightBytesPerRow = (size_t)info.width * 4;
        const size_t bytesPerRow =
            ((tightBytesPerRow + alignment - 1) / alignment) * alignment;
        if ((size_t)info.height > SIZE_MAX / bytesPerRow) {
            dispatch_semaphore_signal(_inflightSemaphore);
            return -1;
        }
        const size_t frameBytes = bytesPerRow * (size_t)info.height;
        if (frameBytes > TB_NATIVE_METAL_MAX_DPCM_DECODED_BYTES) {
            dispatch_semaphore_signal(_inflightSemaphore);
            fprintf(stderr,
                    "[metal-native] rejected TBD2 frame requiring %zu decoded bytes\n",
                    frameBytes);
            return -1;
        }
        if (_dpcmFrameCapacity < frameBytes) {
            _dpcmFrame = [_device newBufferWithLength:frameBytes
                                              options:MTLResourceStorageModePrivate];
            _dpcmFrameCapacity = _dpcmFrame ? frameBytes : 0;
            _dpcmFrameTexture = nil;
            _dpcmFrameTextureBacking = nil;
            _dpcmFrameTextureWidth = 0;
            _dpcmFrameTextureHeight = 0;
            _dpcmFrameTextureBytesPerRow = 0;
            if (_dpcmFrame) {
                os_unfair_lock_lock(&_statsLock);
                _stats.dpcm_decoded_buffer_allocations++;
                _stats.dpcm_decoded_capacity_bytes = _dpcmFrameCapacity;
                os_unfair_lock_unlock(&_statsLock);
            }
        }
        if (!_dpcmFrame) {
            dispatch_semaphore_signal(_inflightSemaphore);
            return -1;
        }
        const BOOL needsTextureView =
            !_dpcmFrameTexture ||
            _dpcmFrameTextureBacking != _dpcmFrame ||
            _dpcmFrameTextureWidth != (size_t)info.width ||
            _dpcmFrameTextureHeight != (size_t)info.height ||
            _dpcmFrameTextureBytesPerRow != bytesPerRow;
        if (needsTextureView) {
            MTLTextureDescriptor *textureDescriptor =
                [MTLTextureDescriptor
                    texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                  width:(NSUInteger)info.width
                                                 height:(NSUInteger)info.height
                                              mipmapped:NO];
            textureDescriptor.usage = MTLTextureUsageShaderRead;
            textureDescriptor.storageMode = MTLStorageModePrivate;
            id<MTLTexture> texture =
                [_dpcmFrame newTextureWithDescriptor:textureDescriptor
                                              offset:0
                                         bytesPerRow:bytesPerRow];
            if (texture) {
                _dpcmFrameTexture = texture;
                _dpcmFrameTextureBacking = _dpcmFrame;
                _dpcmFrameTextureWidth = (size_t)info.width;
                _dpcmFrameTextureHeight = (size_t)info.height;
                _dpcmFrameTextureBytesPerRow = bytesPerRow;
                os_unfair_lock_lock(&_statsLock);
                _stats.dpcm_texture_view_creations++;
                os_unfair_lock_unlock(&_statsLock);
            }
        }
        id<MTLTexture> frameTexture = _dpcmFrameTexture;
        if (!frameTexture) {
            dispatch_semaphore_signal(_inflightSemaphore);
            return -1;
        }

        const CFTimeInterval drawableStarted = CACurrentMediaTime();
        id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
        const double drawableWaitMS =
            (CACurrentMediaTime() - drawableStarted) * 1000.0;
        os_unfair_lock_lock(&_statsLock);
        _stats.drawable_requests++;
        _stats.drawable_wait_ms_total += drawableWaitMS;
        _stats.drawable_wait_histogram[
            tb_native_metal_timing_bucket(drawableWaitMS)]++;
        if (drawableWaitMS > _stats.drawable_wait_ms_max) {
            _stats.drawable_wait_ms_max = drawableWaitMS;
        }
        os_unfair_lock_unlock(&_statsLock);
        if (!drawable) {
            dispatch_semaphore_signal(_inflightSemaphore);
            [self recordDrop];
            return 0;
        }

        /* Lossless source bytes are only useful when the physical presentation
         * is also 1:1. Refuse to silently scale a TBD2 frame when the iMac is in
         * a non-native display mode or the full-screen drawable is not the
         * panel's exact backing size. */
        if (drawable.texture.width != (NSUInteger)info.width ||
            drawable.texture.height != (NSUInteger)info.height) {
            fprintf(stderr,
                    "[metal-native] rejected non-1:1 TBD2 source=%dx%d drawable=%lux%lu\n",
                    info.width,
                    info.height,
                    (unsigned long)drawable.texture.width,
                    (unsigned long)drawable.texture.height);
            dispatch_semaphore_signal(_inflightSemaphore);
            return TB_NATIVE_METAL_RENDER_TRANSIENT_RETRY;
        }

        id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
        if (!commandBuffer) {
            dispatch_semaphore_signal(_inflightSemaphore);
            return -1;
        }
        commandBuffer.label = @"TargetBridge TBD2 Frame";
        id<MTLComputeCommandEncoder> compute =
            [commandBuffer computeCommandEncoder];
        if (!compute) {
            dispatch_semaphore_signal(_inflightSemaphore);
            return -1;
        }

        TBNativeMetalDPCMParams parameters = {
            (uint32_t)info.width,
            (uint32_t)info.height,
            (uint32_t)info.tiles_x,
            (uint32_t)info.tiles_y,
            info.tile_count,
            (uint32_t)(bytesPerRow / 4),
            (uint32_t)info.width_plane_off,
            (uint32_t)info.seed_plane_off,
            (uint32_t)info.payload_off,
            8u,
            0xFF000000u
        };
        [compute setComputePipelineState:_dpcmPipeline];
        [compute setBuffer:upload offset:0 atIndex:0];
        [compute setBuffer:upload offset:info.group_table_off atIndex:1];
        [compute setBuffer:_dpcmFrame offset:0 atIndex:2];
        [compute setBytes:&parameters length:sizeof(parameters) atIndex:3];
        [compute dispatchThreadgroups:MTLSizeMake(info.tile_count, 1, 1)
                   threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [compute endEncoding];

        MTLRenderPassDescriptor *pass =
            [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

        TBNativeMetalUniforms uniforms;
        memset(&uniforms, 0, sizeof(uniforms));
        const CGSize drawableSize = _metalLayer.drawableSize;
        uniforms.drawableSize = (vector_float2){(float)drawableSize.width,
                                                (float)drawableSize.height};
        const float sourceWidth = (float)MAX(1, cursorWidth);
        const float sourceHeight = (float)MAX(1, cursorHeight);
        uniforms.cursorPosition = (vector_float2){
            (float)cursorX * (float)drawableSize.width / sourceWidth,
            (float)cursorY * (float)drawableSize.height / sourceHeight
        };
        const float cursorBase = drawableSize.width >= 5000.0
            ? (cursorLarge ? 58.0f : 32.0f)
            : (cursorLarge ? 44.0f : 24.0f);
        uniforms.cursorSize = (vector_float2){cursorBase * 0.75f,
                                              cursorBase * 1.1875f};
        uniforms.cursorVisible = cursorVisible ? 1u : 0u;
        uniforms.cursorType = (uint32_t)MAX(0, cursorType);
        uniforms.cursorLarge = cursorLarge ? 1u : 0u;
        uniforms.fullRange = 1u;

        id<MTLRenderCommandEncoder> render =
            [commandBuffer renderCommandEncoderWithDescriptor:pass];
        if (!render) {
            dispatch_semaphore_signal(_inflightSemaphore);
            return -1;
        }
        [render setRenderPipelineState:_packedPipeline];
        [render setFragmentTexture:frameTexture atIndex:0];
        [render setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        [render drawPrimitives:MTLPrimitiveTypeTriangleStrip
                   vertexStart:0
                   vertexCount:4];
        [render endEncoding];
        const uint64_t presentationEpoch = [self currentPresentationEpoch];
        __weak TBNativeMetalRenderer *weakSelf = self;
        [drawable addPresentedHandler:^(id<MTLDrawable> presentedDrawable) {
            (void)presentedDrawable;
            [weakSelf recordDrawablePresentedForEpoch:presentationEpoch];
        }];
        [commandBuffer presentDrawable:drawable];

        if (_latestFrame) {
            CVPixelBufferRelease(_latestFrame);
            _latestFrame = NULL;
        }

        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            double gpuMS = 0.0;
            if (completed.GPUEndTime > completed.GPUStartTime) {
                gpuMS = (completed.GPUEndTime - completed.GPUStartTime) * 1000.0;
            }
            const BOOL gpuFailed =
                completed.status != MTLCommandBufferStatusCompleted;
            if (gpuFailed) {
                fprintf(stderr,
                        "[metal-native] TBD2 command buffer failed status=%ld error=%s\n",
                        (long)completed.status,
                        completed.error.localizedDescription.UTF8String ?: "unknown");
            }
            [self recordCommandCompletionFailed:gpuFailed
                                gpuMilliseconds:gpuMS];
            dispatch_semaphore_signal(self->_inflightSemaphore);
        }];

        os_unfair_lock_lock(&_statsLock);
        _stats.submitted_frames++;
        _stats.inflight_frames++;
        if (_stats.inflight_frames > _stats.inflight_frames_max) {
            _stats.inflight_frames_max = _stats.inflight_frames;
        }
        os_unfair_lock_unlock(&_statsLock);
        [commandBuffer commit];
        /* Advance only after a command actually owns this slot. A failed
         * pre-commit attempt returns its semaphore permit and must not skip a
         * ring entry, or a later frame could overwrite an in-flight upload. */
        _dpcmUploadIndex = (_dpcmUploadIndex + 1) % 3;

        const double submitMS =
            (CACurrentMediaTime() - submitStarted) * 1000.0;
        os_unfair_lock_lock(&_statsLock);
        _stats.submit_samples++;
        _stats.submit_time_ms_total += submitMS;
        _stats.submit_time_histogram[tb_native_metal_timing_bucket(submitMS)]++;
        if (submitMS > _stats.submit_time_ms_max) {
            _stats.submit_time_ms_max = submitMS;
        }
        os_unfair_lock_unlock(&_statsLock);

        if (!_loggedFirstFrame) {
            _loggedFirstFrame = YES;
            fprintf(stderr,
                    "[metal-native] first 8-bit TBD2 frame source=%dx%d "
                    "drawable=%lux%lu decoded/presented 1:1 on GPU\n",
                    info.width,
                    info.height,
                    (unsigned long)drawable.texture.width,
                    (unsigned long)drawable.texture.height);
        }
        return 1;
    }
}

- (int)renderCursorX:(int)cursorX
             cursorY:(int)cursorY
         cursorWidth:(int)cursorWidth
        cursorHeight:(int)cursorHeight
       cursorVisible:(BOOL)cursorVisible
         cursorType:(int)cursorType
         cursorLarge:(BOOL)cursorLarge {
    if ([self isRenderAdmissionClosed]) return -1;
    if (!_latestFrame) return 0;
    return [self renderPixelBuffer:_latestFrame
                           cursorX:cursorX
                           cursorY:cursorY
                       cursorWidth:cursorWidth
                      cursorHeight:cursorHeight
                     cursorVisible:cursorVisible
                        cursorType:cursorType
                       cursorLarge:cursorLarge
                     rememberFrame:NO];
}

- (void)copyStats:(struct tb_native_metal_stats *)stats {
    if (!stats) return;
    os_unfair_lock_lock(&_statsLock);
    *stats = _stats;
    os_unfair_lock_unlock(&_statsLock);
}

- (const char *)colorSpaceName {
    return _displayP3 ? "Display P3" : "sRGB";
}

- (BOOL)isRenderAdmissionClosed {
    os_unfair_lock_lock(&_statsLock);
    const BOOL closed = _teardownQuarantined || _terminalGPUError;
    os_unfair_lock_unlock(&_statsLock);
    return closed;
}

- (BOOL)hasTerminalGPUError {
    os_unfair_lock_lock(&_statsLock);
    const BOOL terminal = _terminalGPUError;
    os_unfair_lock_unlock(&_statsLock);
    return terminal;
}

- (BOOL)isTeardownQuarantined {
    os_unfair_lock_lock(&_statsLock);
    const BOOL quarantined = _teardownQuarantined;
    os_unfair_lock_unlock(&_statsLock);
    return quarantined;
}

- (void)beginTeardown {
    /* Close admission before draining. Rendering is normally main-thread-only,
     * but this also makes an accidental concurrent caller fail closed instead
     * of consuming a permit while destruction is trying to acquire all three. */
    os_unfair_lock_lock(&_statsLock);
    _teardownQuarantined = YES;
    os_unfair_lock_unlock(&_statsLock);
}

- (BOOL)waitUntilIdleWithTimeoutNanos:(uint64_t)timeoutNanos {
    /* One absolute deadline bounds the whole drain, rather than granting each
     * of the three slots another full timeout. Restore only permits acquired
     * here: a later completion will restore every still-in-flight permit. */
    const int64_t deadlineDelta = timeoutNanos > (uint64_t)INT64_MAX
        ? INT64_MAX
        : (int64_t)timeoutNanos;
    const dispatch_time_t deadline =
        dispatch_time(DISPATCH_TIME_NOW, deadlineDelta);
    int acquired = 0;
    for (; acquired < 3; acquired++) {
        if (dispatch_semaphore_wait(_inflightSemaphore, deadline) != 0) break;
    }
    for (int slot = 0; slot < acquired; slot++) {
        dispatch_semaphore_signal(_inflightSemaphore);
    }
    if (acquired == 3) return YES;

    os_unfair_lock_lock(&_statsLock);
    _teardownQuarantined = YES;
    os_unfair_lock_unlock(&_statsLock);
    return NO;
}

#if defined(TB_NATIVE_METAL_TESTING)
- (int)testRecordCompletionFailureForPath:(int)completionPath {
    if (completionPath != TB_NATIVE_METAL_TEST_COMPLETION_NV12 &&
        completionPath != TB_NATIVE_METAL_TEST_COMPLETION_DPCM) {
        return -1;
    }
    [self recordCommandCompletionFailed:YES gpuMilliseconds:0.0];
    return 0;
}

- (int)testClaimInflightSlot {
    if (dispatch_semaphore_wait(_inflightSemaphore, DISPATCH_TIME_NOW) != 0) {
        return -1;
    }
    _testClaimedSlots++;
    return 0;
}

- (int)testReleaseInflightSlot {
    if (_testClaimedSlots <= 0) return -1;
    _testClaimedSlots--;
    dispatch_semaphore_signal(_inflightSemaphore);
    return 0;
}
#endif

@end

void *tb_native_metal_create(void) {
    @autoreleasepool {
        TBNativeMetalRenderer *renderer = [[TBNativeMetalRenderer alloc] initRenderer];
        return renderer ? (__bridge_retained void *)renderer : NULL;
    }
}

void tb_native_metal_destroy(void *renderer) {
    if (!renderer) return;
    @autoreleasepool {
        TBNativeMetalRenderer *object = CFBridgingRelease(renderer);
        /* Hide before releasing the caller's bridge retain. If the GPU never
         * completes, every committed command's completion block still owns
         * `self`, quarantining the renderer and its resources instead of
         * risking a use-after-free. */
        [object beginTeardown];
        [object setVisible:NO];
        if (![object waitUntilIdleWithTimeoutNanos:
                TB_NATIVE_METAL_TEARDOWN_TIMEOUT_NSEC]) {
            fprintf(stderr,
                    "[metal-native] GPU drain timed out after 2s; "
                    "renderer quarantined until in-flight completions release it\n");
        }
    }
}

void tb_native_metal_set_visible(void *renderer, int visible) {
    if (!renderer) return;
    @autoreleasepool {
        [(__bridge TBNativeMetalRenderer *)renderer setVisible:visible ? YES : NO];
    }
}

uint64_t tb_native_metal_begin_presentation_session(void *renderer) {
    if (!renderer) return 0;
    @autoreleasepool {
        return [(__bridge TBNativeMetalRenderer *)renderer
            beginPresentationSession];
    }
}

int tb_native_metal_render_nv12(void *renderer,
                                void *pixel_buffer,
                                int cursor_x,
                                int cursor_y,
                                int cursor_source_w,
                                int cursor_source_h,
                                int cursor_visible,
                                int cursor_type,
                                int cursor_large) {
    if (!renderer || !pixel_buffer) return -1;
    @autoreleasepool {
        return [(__bridge TBNativeMetalRenderer *)renderer
            renderPixelBuffer:(CVPixelBufferRef)pixel_buffer
                       cursorX:cursor_x
                       cursorY:cursor_y
                   cursorWidth:cursor_source_w
                  cursorHeight:cursor_source_h
                 cursorVisible:cursor_visible ? YES : NO
                    cursorType:cursor_type
                   cursorLarge:cursor_large ? YES : NO
                 rememberFrame:YES];
    }
}

int tb_native_metal_render_nv12_planes(void *renderer,
                                       const uint8_t *y,
                                       int y_stride,
                                       const uint8_t *uv,
                                       int uv_stride,
                                       int width,
                                       int height,
                                       int cursor_x,
                                       int cursor_y,
                                       int cursor_source_w,
                                       int cursor_source_h,
                                       int cursor_visible,
                                       int cursor_type,
                                       int cursor_large) {
    if (!renderer) return -1;
    @autoreleasepool {
        return [(__bridge TBNativeMetalRenderer *)renderer
            renderNV12PlanesY:y
                       yStride:y_stride
                            uv:uv
                      uvStride:uv_stride
                         width:width
                        height:height
                       cursorX:cursor_x
                       cursorY:cursor_y
                   cursorWidth:cursor_source_w
                  cursorHeight:cursor_source_h
                 cursorVisible:cursor_visible ? YES : NO
                    cursorType:cursor_type
                   cursorLarge:cursor_large ? YES : NO];
    }
}

int tb_native_metal_supports_dpcm(void *renderer) {
    if (!renderer) return 0;
    @autoreleasepool {
        return [(__bridge TBNativeMetalRenderer *)renderer supportsDPCM] ? 1 : 0;
    }
}

int tb_native_metal_render_dpcm(void *renderer,
                                const uint8_t *blob,
                                size_t length,
                                int cursor_x,
                                int cursor_y,
                                int cursor_source_w,
                                int cursor_source_h,
                                int cursor_visible,
                                int cursor_type,
                                int cursor_large) {
    if (!renderer) return -1;
    @autoreleasepool {
        return [(__bridge TBNativeMetalRenderer *)renderer
            renderDPCMBlob:blob
                     length:length
                    cursorX:cursor_x
                    cursorY:cursor_y
                cursorWidth:cursor_source_w
               cursorHeight:cursor_source_h
              cursorVisible:cursor_visible ? YES : NO
                 cursorType:cursor_type
                cursorLarge:cursor_large ? YES : NO];
    }
}

int tb_native_metal_render_cursor(void *renderer,
                                  int cursor_x,
                                  int cursor_y,
                                  int cursor_source_w,
                                  int cursor_source_h,
                                  int cursor_visible,
                                  int cursor_type,
                                  int cursor_large) {
    if (!renderer) return -1;
    @autoreleasepool {
        return [(__bridge TBNativeMetalRenderer *)renderer
            renderCursorX:cursor_x
                 cursorY:cursor_y
             cursorWidth:cursor_source_w
            cursorHeight:cursor_source_h
           cursorVisible:cursor_visible ? YES : NO
              cursorType:cursor_type
             cursorLarge:cursor_large ? YES : NO];
    }
}

void tb_native_metal_get_stats(void *renderer,
                               struct tb_native_metal_stats *stats) {
    if (!stats) return;
    memset(stats, 0, sizeof(*stats));
    if (!renderer) return;
    @autoreleasepool {
        [(__bridge TBNativeMetalRenderer *)renderer copyStats:stats];
    }
}

const char *tb_native_metal_pixel_buffer_color_space(void *pixel_buffer) {
    return tb_pixel_buffer_uses_display_p3((CVPixelBufferRef)pixel_buffer)
        ? "Display P3"
        : "sRGB";
}

const char *tb_native_metal_color_space_name(void *renderer) {
    if (!renderer) return "unavailable";
    @autoreleasepool {
        return [(__bridge TBNativeMetalRenderer *)renderer colorSpaceName];
    }
}

#if defined(TB_NATIVE_METAL_TESTING)
int tb_native_metal_test_record_completion_failure(void *renderer,
                                                    int completion_path) {
    if (!renderer) return -1;
    @autoreleasepool {
        return [(__bridge TBNativeMetalRenderer *)renderer
            testRecordCompletionFailureForPath:completion_path];
    }
}

int tb_native_metal_test_has_terminal_gpu_error(void *renderer) {
    if (!renderer) return 0;
    @autoreleasepool {
        return [(__bridge TBNativeMetalRenderer *)renderer
            hasTerminalGPUError] ? 1 : 0;
    }
}

int tb_native_metal_test_render_admission_result(void *renderer) {
    if (!renderer) return -1;
    @autoreleasepool {
        return [(__bridge TBNativeMetalRenderer *)renderer
            isRenderAdmissionClosed] ? -1 : 1;
    }
}

int tb_native_metal_test_claim_inflight_slot(void *renderer) {
    if (!renderer) return -1;
    @autoreleasepool {
        return [(__bridge TBNativeMetalRenderer *)renderer
            testClaimInflightSlot];
    }
}

int tb_native_metal_test_release_inflight_slot(void *renderer) {
    if (!renderer) return -1;
    @autoreleasepool {
        return [(__bridge TBNativeMetalRenderer *)renderer
            testReleaseInflightSlot];
    }
}

int tb_native_metal_test_drain_with_timeout(void *renderer,
                                            uint64_t timeout_nanoseconds) {
    if (!renderer) return -1;
    @autoreleasepool {
        return [(__bridge TBNativeMetalRenderer *)renderer
            waitUntilIdleWithTimeoutNanos:timeout_nanoseconds] ? 0 : -1;
    }
}

int tb_native_metal_test_is_quarantined(void *renderer) {
    if (!renderer) return 0;
    @autoreleasepool {
        return [(__bridge TBNativeMetalRenderer *)renderer
            isTeardownQuarantined] ? 1 : 0;
    }
}
#endif
