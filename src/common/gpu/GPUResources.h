#pragma once
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

// Reuses same-descriptor private textures across frames instead of allocating
// per frame. Each texture carries a use count; it returns to the free list only
// when every holder has relinquished it, typically on command-buffer completion.
@interface BG3MFXTexturePool : NSObject
@property(nonatomic, readonly) MTLTextureDescriptor *descriptor;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithDevice:(id<MTLDevice>)device descriptor:(MTLTextureDescriptor *)descriptor;
- (BOOL)matchesWidth:(NSUInteger)width height:(NSUInteger)height format:(MTLPixelFormat)format;
// Returns a texture with a use count of one, allocating only when none is free.
- (nullable id<MTLTexture>)acquire;
- (void)retainTexture:(id<MTLTexture>)texture;
- (void)relinquish:(id<MTLTexture>)texture;
- (void)relinquish:(id<MTLTexture>)texture afterCommandBuffer:(id<MTLCommandBuffer>)buffer;
@end

// Pools for private textures that follow the frame's size, by size, format and
// usage. Only the `capacity` most recently used are kept: a window drag or a
// resolution change would otherwise hold every earlier size's textures for the
// rest of the session. Textures in flight still return to an evicted pool, which
// is freed once they have.
@interface BG3MFXTexturePools : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithDevice:(id<MTLDevice>)device capacity:(NSUInteger)capacity;
// A pooled texture, released after `buffer`.
- (nullable id<MTLTexture>)textureWidth:(NSUInteger)width height:(NSUInteger)height format:(MTLPixelFormat)format
                                  usage:(MTLTextureUsage)usage commandBuffer:(id<MTLCommandBuffer>)buffer;
@end

// Runs Metal 4 FX work between earlier and later commands of a Metal 3 command
// buffer, entirely on the GPU timeline. Allocators, command buffers, events and
// the residency set are reused once their previous submission completes.
@interface BG3MFXMetal4Bridge : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device label:(NSString *)label error:(NSError **)error;
// `allocations` are made resident for this submission. `retained` objects and
// the allocations stay alive until the GPU reports completion. `encode` may run
// later (see submission order below), so it must capture every value it uses.
- (BOOL)encodeIntoBuffer:(id<MTLCommandBuffer>)buffer
             allocations:(NSArray<id<MTLAllocation>> *)allocations
                retained:(NSArray *)retained
                  encode:(void (^)(id<MTL4CommandBuffer> commands))encode
                 failure:(nullable void (^)(NSError *error))failure
                   error:(NSError **)error;
// The residency set retains its allocations. Drop it while idle; submissions
// in flight keep their own reference, and the next one starts a new set.
- (void)releaseResidency;
@end

// Submission order. A bridge submission waits on its Metal 4 queue for a signal
// from the command buffer it is encoded into, so it must reach that queue in the
// GPU order of those buffers. BG3 fixes that order with -enqueue and encodes the
// buffers afterwards, on several threads; submitted in encoding order, a queue
// could wait on a buffer that runs after one waiting on the queue (a GPU
// timeout). Temporal effects also link each frame to the one encoded before it.
// For tracked buffers, submissions are recorded and submitted once the buffer
// and every buffer enqueued before it on its queue have been committed; a
// buffer that is never committed never submits. Untracked buffers submit
// immediately.
void BG3MFXMetal4TrackBuffer(id<MTLCommandBuffer> buffer);
// The runtime's -enqueue and -commit hooks: `call` is the original method.
void BG3MFXMetal4Enqueue(id<MTLCommandBuffer> buffer, void (NS_NOESCAPE ^call)(void));
void BG3MFXMetal4Commit(id<MTLCommandBuffer> buffer, void (NS_NOESCAPE ^call)(void));
// Submissions that reached their queue in another order than they were encoded
// in (each would have waited on the GPU without the ordering).
uint64_t BG3MFXMetal4Reordered(void);

// Diagnostics and lab mode (both runtimes): when set, receives each Metal 4
// bridge submission's GPU time.
extern "C" void (*_Nullable BG3MFXGPUTimingHook)(NSString *label, double gpuSeconds);
#ifndef BG3MFX_NO_TRACE
// Diagnostics: when set, receives each change to a bridge's residency set: its
// allocation count and bytes after the change, how many allocations were added,
// and whether the set was rebuilt (dropping members idle for 16 submissions,
// or on reaching its 64-allocation bound).
extern "C" void (*_Nullable BG3MFXResidencyHook)(NSString *label, NSUInteger allocations, uint64_t bytes,
    NSUInteger added, BOOL replaced);
#endif

NS_ASSUME_NONNULL_END

// Total textures ever allocated by pools in this process (regression checks).
#if !defined(BG3MFX_NO_TRACE) || defined(BG3MFX_STANDALONE_TEST_HOOKS)
extern "C" NSUInteger BG3MFXTexturePoolAllocations(void);
#endif
