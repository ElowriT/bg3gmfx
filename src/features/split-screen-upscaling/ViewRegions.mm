#import "features/split-screen-upscaling/ViewRegions.h"
#import "common/gpu/GPUResources.h"
#include <cmath>
#include <mutex>

MTLRegion BG3MFXViewRegion(NSArray<NSNumber *> *view) {
    return MTLRegionMake2D(view[0].unsignedIntegerValue, view[1].unsignedIntegerValue,
                           view[2].unsignedIntegerValue, view[3].unsignedIntegerValue);
}

MTLRegion BG3MFXScaleViewRegion(NSArray<NSNumber *> *view, NSUInteger inputWidth, NSUInteger inputHeight,
                                NSUInteger outputWidth, NSUInteger outputHeight) {
    MTLRegion in = BG3MFXViewRegion(view);
    auto scale = [](NSUInteger v, NSUInteger from, NSUInteger to) { return (NSUInteger)std::llround((double)v * to / from); };
    NSUInteger x0 = scale(in.origin.x, inputWidth, outputWidth), x1 = scale(in.origin.x + in.size.width, inputWidth, outputWidth);
    NSUInteger y0 = scale(in.origin.y, inputHeight, outputHeight), y1 = scale(in.origin.y + in.size.height, inputHeight, outputHeight);
    return MTLRegionMake2D(x0, y0, x1 - x0, y1 - y0);
}

@implementation BG3MFXViewRegions {
    // Two views of different sizes use eight pools (Temporal's three crops and
    // an output each); twice that also keeps the previous size's.
    BG3MFXTexturePools *_pools;
}

+ (instancetype)sharedForDevice:(id<MTLDevice>)device {
    static std::mutex lock;
    static NSMapTable *instances;
    std::lock_guard<std::mutex> hold(lock);
    if (!instances) instances = [NSMapTable weakToStrongObjectsMapTable];
    BG3MFXViewRegions *instance = [instances objectForKey:device];
    if (!instance && device) {
        instance = [[self alloc] init];
        instance->_pools = [[BG3MFXTexturePools alloc] initWithDevice:device capacity:16];
        [instances setObject:instance forKey:device];
    }
    return instance;
}

- (id<MTLTexture>)textureWidth:(NSUInteger)width height:(NSUInteger)height format:(MTLPixelFormat)format
                 commandBuffer:(id<MTLCommandBuffer>)buffer {
    // Depth crops are read only; color and motion crops and outputs are also written by MetalFX or kernels.
    bool depth = format == MTLPixelFormatDepth32Float_Stencil8 || format == MTLPixelFormatDepth32Float;
    return [_pools textureWidth:width height:height format:format
        usage:MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget | (depth ? 0 : MTLTextureUsageShaderWrite) commandBuffer:buffer];
}

- (id<MTLTexture>)copyRegion:(MTLRegion)region of:(id<MTLTexture>)source commandBuffer:(id<MTLCommandBuffer>)buffer {
    if (region.origin.x + region.size.width > source.width || region.origin.y + region.size.height > source.height) return nil;
    id<MTLTexture> copy = [self textureWidth:region.size.width height:region.size.height format:source.pixelFormat commandBuffer:buffer];
    id<MTLBlitCommandEncoder> blit = copy ? [buffer blitCommandEncoder] : nil;
    if (!blit) return nil;
    [blit copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:region.origin sourceSize:region.size
                toTexture:copy destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    return copy;
}

- (BOOL)place:(id<MTLTexture>)source into:(id<MTLTexture>)destination at:(MTLOrigin)origin commandBuffer:(id<MTLCommandBuffer>)buffer {
    if (source.pixelFormat != destination.pixelFormat || origin.x + source.width > destination.width ||
        origin.y + source.height > destination.height) return NO;
    id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
    if (!blit) return NO;
    [blit copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(source.width, source.height, 1) toTexture:destination destinationSlice:0
         destinationLevel:0 destinationOrigin:origin];
    [blit endEncoding];
    return YES;
}

@end
