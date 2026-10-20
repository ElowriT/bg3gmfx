#import "features/metalfx-sharpening/Sharpening.h"
#import "common/gpu/GPUResources.h"
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <mutex>
#include <objc/runtime.h>

static std::atomic<bool> sharpening{[] { const char *v = getenv("BG3MFX_METALFX_SHARPENING"); return !v || strcmp(v, "0") != 0; }()};
bool BG3MFXSharpeningEnabled(void) { return sharpening.load(std::memory_order_relaxed); }
void BG3MFXSetSharpeningEnabled(bool enabled) { sharpening = enabled; }

@implementation BG3MFXNativeSharpening {
    id<MTLDevice> _device;
    id<MTLComputePipelineState> _toFSRSpace;
    NSMutableDictionary<NSString *, BG3MFXTexturePool *> *_pools, *_fsrSpacePools;
    std::mutex _lock;
}

+ (instancetype)sharedForDevice:(id<MTLDevice>)device {
    static std::mutex lock;
    static NSMapTable *instances;
    std::lock_guard<std::mutex> hold(lock);
    if (!instances) instances = [NSMapTable weakToStrongObjectsMapTable];
    BG3MFXNativeSharpening *instance = [instances objectForKey:device];
    if (!instance) {
        instance = [[self alloc] initWithDevice:device];
        if (instance) [instances setObject:instance forKey:device];
    }
    return instance;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if (!(self = [super init])) return nil;
    _device = device;
    _pools = [NSMutableDictionary dictionary];
    _fsrSpacePools = [NSMutableDictionary dictionary];
    // FSR_Tonemap's mapping, which FSR_RCAS undoes (c / (1 - max(c))) when it
    // writes BG3's RG11B10 target, which Metal fills rounding toward zero. The
    // MetalFX result is already on that grid, and the undo magnifies rounding by
    // 1 / (1 - max(c)), so a value rounded down to half float here comes back a
    // step darker. Rounding up instead returns at or just above it.
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void BG3MFXToFSRSpace(texture2d<float,access::read> src [[texture(0)]], "
        "texture2d<half,access::write> dst [[texture(1)]], constant uint4 &area [[buffer(0)]], "
        "uint2 g [[thread_position_in_grid]]) {\n"
        "  uint2 p = g + area.xy;\n"
        "  if (p.x >= area.z || p.y >= area.w) return;\n"
        "  float3 c = max(src.read(p).rgb, 0.0);\n"
        "  float3 t = c / (max3(c.r, c.g, c.b) + 1.0);\n"
        "  half3 h = half3(t);\n"
        "  h = select(h, as_type<half3>(ushort3(as_type<ushort3>(h) + 1)), float3(h) < t);\n"
        "  dst.write(half4(h, 1.0h), p);\n"
        "}\n";
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    id<MTLFunction> function = [library newFunctionWithName:@"BG3MFXToFSRSpace"];
    _toFSRSpace = function ? [device newComputePipelineStateWithFunction:function error:&error] : nil;
    if (!_toFSRSpace) { NSLog(@"BG3 MetalFX: sharpening unavailable: %@", error.localizedDescription); return nil; }
    return self;
}

- (id<MTLTexture>)intermediateLike:(id<MTLTexture>)destination commandBuffer:(id<MTLCommandBuffer>)buffer {
    // The final target's format: each MetalFX scaler writes the one it was made for.
    NSString *key = [NSString stringWithFormat:@"%lu:%lu:%lu", (unsigned long)destination.width,
                     (unsigned long)destination.height, (unsigned long)destination.pixelFormat];
    BG3MFXTexturePool *pool;
    {
        std::lock_guard<std::mutex> hold(_lock);
        pool = _pools[key];
        if (!pool) {
            MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:destination.pixelFormat
                width:destination.width height:destination.height mipmapped:NO];
            desc.storageMode = MTLStorageModePrivate;
            desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
            pool = _pools[key] = [[BG3MFXTexturePool alloc] initWithDevice:_device descriptor:desc];
        }
    }
    id<MTLTexture> texture = [pool acquire];
    if (texture) [pool relinquish:texture afterCommandBuffer:buffer];
    return texture;
}

// RCAS's input in FSR's space. BG3's own FSR output is RG11B10, whose rounding
// RCAS's undo magnifies near white; half float keeps highlights intact. One per
// destination and command buffer, shared by its split-screen views.
static char fsrSpacesKey;
- (id<MTLTexture>)fsrSpaceLike:(id<MTLTexture>)destination commandBuffer:(id<MTLCommandBuffer>)buffer {
    NSMutableDictionary *shared = objc_getAssociatedObject(buffer, &fsrSpacesKey);
    NSValue *bufferKey = [NSValue valueWithPointer:(__bridge const void *)destination];
    if (id<MTLTexture> texture = shared[bufferKey]) return texture;
    NSString *key = [NSString stringWithFormat:@"%lu:%lu", (unsigned long)destination.width, (unsigned long)destination.height];
    BG3MFXTexturePool *pool;
    {
        std::lock_guard<std::mutex> hold(_lock);
        pool = _fsrSpacePools[key];
        if (!pool) {
            MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                width:destination.width height:destination.height mipmapped:NO];
            desc.storageMode = MTLStorageModePrivate;
            desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
            pool = _fsrSpacePools[key] = [[BG3MFXTexturePool alloc] initWithDevice:_device descriptor:desc];
        }
    }
    id<MTLTexture> texture = [pool acquire];
    if (!texture) return nil;
    [pool relinquish:texture afterCommandBuffer:buffer];
    if (!shared) {
        shared = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(buffer, &fsrSpacesKey, shared, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    shared[bufferKey] = texture;
    return texture;
}

- (BOOL)encodeFrom:(id<MTLTexture>)linear rcas:(NSDictionary *)rcas
       destination:(id<MTLTexture>)destination region:(MTLRegion)region commandBuffer:(id<MTLCommandBuffer>)buffer
          dispatch:(void (^)(id<MTLComputeCommandEncoder>, NSDictionary *, MTLSize))dispatch {
    id<MTLComputePipelineState> pipeline = rcas[@"pipeline"];
    id<MTLTexture> fsrSpace = pipeline ? [self fsrSpaceLike:destination commandBuffer:buffer] : nil;
    if (!fsrSpace) return NO;
    id<MTLComputeCommandEncoder> encoder = [buffer computeCommandEncoder];
    if (!encoder) return NO;
    encoder.label = @"BG3MFX native sharpening";
    // The region and the one-pixel ring RCAS reads around it.
    NSUInteger right = std::min(destination.width, region.origin.x + region.size.width);
    NSUInteger bottom = std::min(destination.height, region.origin.y + region.size.height);
    uint32_t area[4] = {(uint32_t)(region.origin.x ? region.origin.x - 1 : 0), (uint32_t)(region.origin.y ? region.origin.y - 1 : 0),
                        (uint32_t)std::min(destination.width, right + 1), (uint32_t)std::min(destination.height, bottom + 1)};
    [encoder setComputePipelineState:_toFSRSpace];
    [encoder setTexture:linear atIndex:0];
    [encoder setTexture:fsrSpace atIndex:1];
    [encoder setBytes:area length:sizeof(area) atIndex:0];
    MTLSize threads = MTLSizeMake(16, 16, 1);
    [encoder dispatchThreadgroups:MTLSizeMake((area[2] - area[0] + 15) / 16, (area[3] - area[1] + 15) / 16, 1) threadsPerThreadgroup:threads];
    [encoder memoryBarrierWithScope:MTLBarrierScopeTextures];
    [encoder setComputePipelineState:pipeline];
    [encoder setTexture:fsrSpace atIndex:0];
    [encoder setTexture:rcas[@"hairMask"] atIndex:1];
    [encoder setTexture:destination atIndex:2];
    if (NSData *bytes = rcas[@"constants"]) [encoder setBytes:bytes.bytes length:bytes.length atIndex:0];
    else [encoder setBuffer:rcas[@"constantsBuffer"] offset:[rcas[@"constantsOffset"] unsignedIntegerValue] atIndex:0];
    dispatch(encoder, rcas, MTLSizeMake(right, bottom, 1));
    [encoder endEncoding];
    return YES;
}

@end
