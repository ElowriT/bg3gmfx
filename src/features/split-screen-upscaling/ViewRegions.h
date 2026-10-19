#pragma once
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

// Split-screen views. BG3 renders each split-screen view into its own rectangle
// of shared full-size textures, then runs FSR over the whole frame once per
// view. MetalFX has no notion of a sub-rectangle, so each view's inputs are
// copied into view-sized textures, upscaled by a scaler of its own (with its own
// history), and the result is copied into the view's rectangle of the output.
// Upscaling the two halves separately also keeps either from sampling the other.
@interface BG3MFXViewRegions : NSObject
+ (nullable instancetype)sharedForDevice:(id<MTLDevice>)device;
// A pooled texture holding `region` of `source` (same format), released after `buffer`.
- (nullable id<MTLTexture>)copyRegion:(MTLRegion)region of:(id<MTLTexture>)source commandBuffer:(id<MTLCommandBuffer>)buffer;
// A pooled render/shader-writable texture, released after `buffer`.
- (nullable id<MTLTexture>)textureWidth:(NSUInteger)width height:(NSUInteger)height format:(MTLPixelFormat)format
                          commandBuffer:(id<MTLCommandBuffer>)buffer;
- (BOOL)place:(id<MTLTexture>)source into:(id<MTLTexture>)destination at:(MTLOrigin)origin commandBuffer:(id<MTLCommandBuffer>)buffer;
@end

// The view rectangle [x, y, width, height] in the input, scaled to the output.
// Neighbouring views meet exactly, since both edges round the same way.
MTLRegion BG3MFXViewRegion(NSArray<NSNumber *> *view);
MTLRegion BG3MFXScaleViewRegion(NSArray<NSNumber *> *view, NSUInteger inputWidth, NSUInteger inputHeight,
                                NSUInteger outputWidth, NSUInteger outputHeight);

NS_ASSUME_NONNULL_END
