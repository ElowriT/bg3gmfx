#import "common/gpu/GPUResources.h"
#include <atomic>
#include <deque>
#include <mutex>
#include <unordered_map>
#include <objc/runtime.h>

#if !defined(BG3MFX_NO_TRACE) || defined(BG3MFX_STANDALONE_TEST_HOOKS)
static std::atomic<NSUInteger> poolAllocations{0};
extern "C" NSUInteger BG3MFXTexturePoolAllocations(void) { return poolAllocations.load(); }
#endif
extern "C" void (*BG3MFXGPUTimingHook)(NSString *, double) = nullptr;

static NSError *resourceError(NSString *reason) {
    return [NSError errorWithDomain:@"BG3MFXGPUResources" code:1 userInfo:@{NSLocalizedDescriptionKey:reason}];
}

@implementation BG3MFXTexturePool {
    id<MTLDevice> _device;
    std::mutex _mutex;
    NSMutableArray<id<MTLTexture>> *_free;
    // Keyed by object identity; the value array keeps each pooled texture alive.
    std::unordered_map<const void *, int> _uses;
    NSMutableArray<id<MTLTexture>> *_all;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device descriptor:(MTLTextureDescriptor *)descriptor {
    if (!(self=[super init])) return nil;
    _device=device; _descriptor=[descriptor copy]; _free=[NSMutableArray array]; _all=[NSMutableArray array];
    return self;
}
- (BOOL)matchesWidth:(NSUInteger)width height:(NSUInteger)height format:(MTLPixelFormat)format {
    return _descriptor.width==width && _descriptor.height==height && _descriptor.pixelFormat==format;
}
- (id<MTLTexture>)acquire {
    std::lock_guard<std::mutex> lock(_mutex);
    id<MTLTexture> texture=_free.lastObject;
    if (texture) [_free removeLastObject];
    else {
        texture=[_device newTextureWithDescriptor:_descriptor];
        if (!texture) return nil;
        [_all addObject:texture];
#if !defined(BG3MFX_NO_TRACE) || defined(BG3MFX_STANDALONE_TEST_HOOKS)
        ++poolAllocations;
#endif
    }
    _uses[(__bridge const void *)texture]=1;
    return texture;
}
- (void)retainTexture:(id<MTLTexture>)texture {
    std::lock_guard<std::mutex> lock(_mutex);
    auto found=_uses.find((__bridge const void *)texture);
    if (found!=_uses.end()) ++found->second;
}
- (void)relinquish:(id<MTLTexture>)texture {
    std::lock_guard<std::mutex> lock(_mutex);
    auto found=_uses.find((__bridge const void *)texture);
    if (found==_uses.end() || --found->second>0) return;
    _uses.erase(found); [_free addObject:texture];
}
- (void)relinquish:(id<MTLTexture>)texture afterCommandBuffer:(id<MTLCommandBuffer>)buffer {
    // The handler keeps the pool alive until the GPU no longer needs the texture.
    BG3MFXTexturePool *pool=self;
    [buffer addCompletedHandler:^(id<MTLCommandBuffer>) { [pool relinquish:texture]; }];
}
@end

// Submission order (see GPUResources.h). Per command queue, the tracked buffers
// in GPU order; each buffer holds its pending submissions until it is committed.
static std::atomic<uint64_t> reordered{0};
uint64_t BG3MFXMetal4Reordered(void) { return reordered.load(std::memory_order_relaxed); }
static std::recursive_mutex &orderLock() { static auto *lock=new std::recursive_mutex; return *lock; }
static std::unordered_map<const void *, std::deque<id<MTLCommandBuffer>>> &orderQueues() {
    static auto *queues=new std::unordered_map<const void *, std::deque<id<MTLCommandBuffer>>>; return *queues;
}
static char orderStateKey, orderPendingKey;
enum : int { OrderUntracked=0, OrderTracked, OrderEnqueued, OrderCommitted };
static int orderState(id buffer) { return [objc_getAssociatedObject(buffer,&orderStateKey) intValue]; }
static void setOrderState(id buffer, int state) {
    objc_setAssociatedObject(buffer,&orderStateKey,@(state),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
void BG3MFXMetal4TrackBuffer(id<MTLCommandBuffer> buffer) { setOrderState(buffer,OrderTracked); }
// Gives `buffer` its place in its queue's GPU order (order lock held).
static void placeInOrder(id<MTLCommandBuffer> buffer) {
    if (orderState(buffer)!=OrderTracked) return;
    setOrderState(buffer,OrderEnqueued);
    orderQueues()[(__bridge const void *)buffer.commandQueue].push_back(buffer);
}
void BG3MFXMetal4Enqueue(id<MTLCommandBuffer> buffer, void (NS_NOESCAPE ^call)(void)) {
    if (orderState(buffer)==OrderUntracked) { call(); return; }
    std::lock_guard<std::recursive_mutex> lock(orderLock());
    call(); placeInOrder(buffer);
}
void BG3MFXMetal4Commit(id<MTLCommandBuffer> buffer, void (NS_NOESCAPE ^call)(void)) {
    if (orderState(buffer)==OrderUntracked) { call(); return; }
    std::lock_guard<std::recursive_mutex> lock(orderLock());
    placeInOrder(buffer);  // a buffer never enqueued takes its place at commit
    setOrderState(buffer,OrderCommitted);
    auto &buffers=orderQueues()[(__bridge const void *)buffer.commandQueue];
    while (!buffers.empty() && orderState(buffers.front())==OrderCommitted) {
        id<MTLCommandBuffer> next=buffers.front(); buffers.pop_front();
        NSArray *pending=objc_getAssociatedObject(next,&orderPendingKey);
        objc_setAssociatedObject(next,&orderPendingKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (void (^submit)(void) in pending) submit();
    }
    call();
}
// Holds `submit` until `buffer`'s turn; NO when it should run now.
static BOOL deferSubmission(id<MTLCommandBuffer> buffer, void (^submit)(void)) {
    if (orderState(buffer)==OrderUntracked) return NO;
    std::lock_guard<std::recursive_mutex> lock(orderLock());
    if (orderState(buffer)==OrderCommitted) return NO;
    NSMutableArray *pending=objc_getAssociatedObject(buffer,&orderPendingKey);
    if (!pending) {
        pending=[NSMutableArray array];
        objc_setAssociatedObject(buffer,&orderPendingKey,pending,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [pending addObject:[submit copy]];
    return YES;
}

// One reusable Metal 4 submission. Its event values increase per reuse, so a
// slot's signal never moves backwards even if BG3 commits buffers out of order.
@interface BG3MFXMetal4Slot : NSObject
@property(nonatomic) id<MTL4CommandAllocator> allocator;
@property(nonatomic) id<MTL4CommandBuffer> commands;
@property(nonatomic) id<MTLEvent> event;
@property(nonatomic) uint64_t value;
@end
@implementation BG3MFXMetal4Slot
@end

@implementation BG3MFXMetal4Bridge {
    id<MTLDevice> _device;
    id<MTL4CommandQueue> _queue;
    id<MTLResidencySet> _residency;
    NSString *_label;
    std::mutex _mutex;
    NSMutableArray<BG3MFXMetal4Slot *> *_free;
    uint64_t _encoded, _submitted;  // submission numbers in encoding order
}
- (instancetype)initWithDevice:(id<MTLDevice>)device label:(NSString *)label error:(NSError **)error {
    if (!(self=[super init])) return nil;
    auto descriptor=[MTL4CommandQueueDescriptor new]; descriptor.label=label;
    _device=device; _label=[label copy]; _queue=[device newMTL4CommandQueueWithDescriptor:descriptor error:error];
    _free=[NSMutableArray array];
    if (!_queue) { if (error && !*error) *error=resourceError(@"Could not create the Metal 4 queue."); return nil; }
    return self;
}
- (id<MTLResidencySet>)residencyFor:(NSArray<id<MTLAllocation>> *)allocations error:(NSError **)error {
    std::lock_guard<std::mutex> lock(_mutex);
    // A full set is replaced rather than cleared: in-flight submissions keep
    // using the previous one. Replacement bounds growth from resized inputs.
    if (!_residency || _residency.allocationCount+allocations.count>64) {
        auto descriptor=[MTLResidencySetDescriptor new]; descriptor.initialCapacity=16;
        _residency=[_device newResidencySetWithDescriptor:descriptor error:error];
        if (!_residency) return nil;
    }
    BOOL changed=NO;
    for (id<MTLAllocation> allocation in allocations)
        if (![_residency containsAllocation:allocation]) { [_residency addAllocation:allocation]; changed=YES; }
    if (changed) [_residency commit];
    return _residency;
}
- (BOOL)encodeIntoBuffer:(id<MTLCommandBuffer>)buffer allocations:(NSArray<id<MTLAllocation>> *)allocations
                retained:(NSArray *)retained encode:(void (^)(id<MTL4CommandBuffer>))encode
                 failure:(void (^)(NSError *))failure error:(NSError **)error {
    id<MTLResidencySet> residency=[self residencyFor:allocations error:error];
    if (!residency) { if (error && !*error) *error=resourceError(@"Could not create a residency set."); return NO; }
    BG3MFXMetal4Slot *slot;
    { std::lock_guard<std::mutex> lock(_mutex); slot=_free.lastObject; if (slot) [_free removeLastObject]; }
    if (!slot) {
        slot=[BG3MFXMetal4Slot new];
        slot.allocator=[_device newCommandAllocator]; slot.commands=[_device newCommandBuffer]; slot.event=[_device newEvent];
        if (!slot.allocator || !slot.commands || !slot.event) {
            if (error) *error=resourceError(@"Could not allocate a Metal 4 submission."); return NO;
        }
    }
    uint64_t sequence;
    { std::lock_guard<std::mutex> lock(_mutex); sequence=++_encoded; }
    uint64_t ready=++slot.value, done=++slot.value;
    // Metal 4 command buffers do not retain allocations; keep everything the
    // submission touches alive until GPU feedback, then recycle the slot.
    NSMutableArray *flight=[NSMutableArray arrayWithArray:retained];
    [flight addObjectsFromArray:allocations]; [flight addObject:residency];
    BG3MFXMetal4Bridge *bridge=self; void (^report)(NSError *)=[failure copy];
    NSString *label=_label;
    auto options=[MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
        if (feedback.error && report) report(feedback.error);
        if (auto hook=BG3MFXGPUTimingHook) hook(label,feedback.GPUEndTime-feedback.GPUStartTime);
        [flight removeAllObjects];
        [slot.allocator reset];
        std::lock_guard<std::mutex> lock(bridge->_mutex); [bridge->_free addObject:slot];
    }];
    id<MTL4CommandQueue> queue=_queue; id<MTLEvent> event=slot.event; id<MTL4CommandBuffer> commands=slot.commands;
    id<MTL4CommandAllocator> allocator=slot.allocator; void (^record)(id<MTL4CommandBuffer>)=[encode copy];
    // Recorded at submission: a temporal effect links each frame to the one
    // encoded before it, so it must see frames in the order the GPU runs them.
    void (^submit)(void)=^{
        [commands beginCommandBufferWithAllocator:allocator];
        [commands useResidencySet:residency];
        record(commands);
        [commands endCommandBuffer];
        {
            std::lock_guard<std::mutex> lock(bridge->_mutex);
            if (sequence<bridge->_submitted) reordered.fetch_add(1,std::memory_order_relaxed);
            else bridge->_submitted=sequence;
        }
        id<MTL4CommandBuffer> list=commands;
        [queue waitForEvent:event value:ready];
        [queue commit:&list count:1 options:options];
        [queue signalEvent:event value:done];
    };
    [buffer encodeSignalEvent:slot.event value:ready];
    [buffer encodeWaitForEvent:slot.event value:done];
    if (!deferSubmission(buffer,submit)) submit();
    return YES;
}
@end
