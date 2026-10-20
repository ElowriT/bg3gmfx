#pragma once
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

// MetalFX output with BG3's own sharpening. BG3's native chain is FSR_Tonemap
// (c / (1 + max(c))), FSR (EASU) and FSR_RCAS, which sharpens in that space,
// skips hair, and writes linear HDR (c / (1 - max(c))). MetalFX replaces FSR and
// RCAS and writes linear HDR, which dropped the player's Sharpness setting. With
// sharpening, MetalFX writes a pooled texture instead; it is mapped into FSR's
// space in a half-float texture, and BG3's FSR_RCAS dispatch is replayed with
// its own pipeline, constants, hair mask and grid into the final target.
// BG3MFX_METALFX_SHARPENING=0 keeps the unsharpened MetalFX output.
@interface BG3MFXNativeSharpening : NSObject
+ (nullable instancetype)sharedForDevice:(id<MTLDevice>)device;
// A pooled texture like destination for MetalFX to write; released after buffer.
- (nullable id<MTLTexture>)intermediateLike:(id<MTLTexture>)destination commandBuffer:(id<MTLCommandBuffer>)buffer;
// rcas: the replayed dispatch (see Trace.mm, FSR_RCAS). region: the part of
// destination this pass is for (all of it, or one split-screen view). Only that
// part (and the pixels RCAS reads around it) is mapped into FSR's space, into a
// texture the command buffer's views share, so a later view's whole-frame pass
// still reads every earlier view. dispatch issues the dispatch on the encoder
// without bg3mfx's own dispatch hook; extent is the region's far corner, which
// a dispatch from the origin needs to cover.
- (BOOL)encodeFrom:(id<MTLTexture>)linear
              rcas:(NSDictionary *)rcas
       destination:(id<MTLTexture>)destination
            region:(MTLRegion)region
     commandBuffer:(id<MTLCommandBuffer>)buffer
          dispatch:(void (^)(id<MTLComputeCommandEncoder> encoder, NSDictionary *rcas, MTLSize extent))dispatch;
@end

// Default on; BG3MFX_METALFX_SHARPENING=0 or the lab switch turn it off.
bool BG3MFXSharpeningEnabled(void);
void BG3MFXSetSharpeningEnabled(bool enabled);

NS_ASSUME_NONNULL_END
