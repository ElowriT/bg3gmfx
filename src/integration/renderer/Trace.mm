#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <objc/runtime.h>
#include <atomic>
#include <string>
#include <algorithm>
#include <vector>
#import "common/gpu/MetalFXPipeline.h"
#import "features/cluster-buffer-guard/ClusterBufferGuard.h"
#import "features/depth-prepass/DepthPrepass.h"
#import "features/render-thread-optimizations/BindFilter.h"
#import "features/dynamic-worker-prioritization/DynamicWorkers.h"
#import "features/metalfx-spatial-upscaling/SpatialUpscaler.h"
#import "features/metalfx-temporal-upscaling/TemporalUpscaler.h"
#import "integration/menu/NativeMenu.h"
#import "features/split-screen-fog/SplitScreenFog.h"
#import "integration/lab/LabInput.h"
#import "features/metalfx-sharpening/Sharpening.h"
#import "features/split-screen-upscaling/ViewRegions.h"
#ifndef BG3MFX_NO_TRACE
#endif
#import "features/metalfx-frame-generation/FrameInterpolation.h"
#import "features/metalfx-frame-generation/FrameLog.h"
#import "common/gpu/GPUResources.h"
#import <QuartzCore/CAMetalLayer.h>
#include <mach/mach_time.h>
#include <cmath>
#include <cstring>
#include <map>
#include <mutex>
#include <set>
#include <fcntl.h>
#include <unistd.h>
#include <dlfcn.h>

// Discover concrete driver classes from instances; never depend on an AGX class name.
// dyld may run the constructor before this translation unit's C++ initializers.
// Function-local statics guarantee initialization before the first hook/log call.
static std::recursive_mutex &guard() { static auto *value = new std::recursive_mutex; return *value; }
static std::map<std::pair<Class, SEL>, IMP> &originals() {
    static auto *value = new std::map<std::pair<Class, SEL>, IMP>;
    return *value;
}
// The replacement each hooked method received, to recognize it under another name.
static std::map<std::pair<Class, SEL>, IMP> &replacements() {
    static auto *value = new std::map<std::pair<Class, SEL>, IMP>;
    return *value;
}
static NSMutableSet<NSString *> *seen;
static NSFileHandle *output;
static unsigned long frames;
static unsigned long resourceCounter;
static char resourceKey, pipelineKey, bindingsKey, attachmentsKey;
static BOOL traceConstants;
#ifdef BG3MFX_NO_TRACE
static constexpr bool diagnostics = false;
// Compile away the arguments too: a no-op function would still construct the
// dictionaries, texture descriptions and strings on every intercepted call.
#define record(...) ((void)0)
#else
static constexpr bool diagnostics = true;
#endif
// Lab mode's own upscaling events (input-log.jsonl), in both runtimes. Unlike
// record(), its arguments are built only in lab mode, so they must never be nil.
static bool labRecording;
static void labRecordEvent(NSDictionary *event);
#define labRecord(...) do { if (labRecording) labRecordEvent(__VA_ARGS__); } while (0)
static NSMutableDictionary<NSString *, NSNumber *> *constantSamples;
static NSMutableDictionary<NSString *, NSDictionary *> *shaderBufferSizes;
#ifndef BG3MFX_NO_TRACE
#endif
static BOOL sceneProbe;
static BOOL metalFXEnabled;
static char bufferScalingModeKey;
static char frameGenerationModeKey, compositorSizeKey, frameCompositionKey, generatedPairKey;
static thread_local bool encodingFrameGeneration=false;
static char deferredPresentKey;
#ifndef BG3MFX_NO_TRACE
static std::atomic<unsigned> deferredPresents{0}, pairedPresents{0}, replayedPresents{0};
#endif
static bool frameGeneration(id buffer) { return [objc_getAssociatedObject(buffer,&frameGenerationModeKey) boolValue]; }
// Scene color, depth, motion and camera are associated with BG3's TAA output and
// followed through post-processing: for MetalFX Spatial and Temporal, and for
// every Upscaling Type while Frame Generation needs them at the composition.
static bool sceneTracked(int mode, id buffer) { return mode == 2 || mode == 3 || (buffer && frameGeneration(buffer)); }

// Per-encoder hook state, one object per encoder. BG3 issues about 12,000 draws
// and many more binds per frame; sampling showed half of its render thread in
// these hooks when they built strings and dictionaries per call. Binds now
// write fixed slots, and draws do real work only for the few pipelines the
// integration recognizes (classified once, at pipeline creation).
enum EncoderStage : uint8_t { StageVertex, StageFragment, StageCompute };
enum PipelineKind : uint8_t {
    PipelineOther, PipelineTAA, PipelineLinearizeDepth, PipelineVelocity,
    PipelinePostColor, PipelineToneMapLUT, PipelineCombineUI, PipelineSceneOverlay,
};
// Prepass trim (docs/dev/performance.md): vertex-only opaque draws are skipped in the
// depth prepass, and their G-buffer draws write depth instead of testing Equal
// against it, as BG3's terrain already does. Separate from PipelineKind so the
// scene-tracking logic still sees these pipelines as unrecognized.
static bool prepassTrim;
#ifndef BG3MFX_NO_TRACE
#endif
// Bind dedup: BG3 rebinds about 27 fragment texture slots per call when about
// two change (92% of slots repeat the current binding), and re-sets the bound
// pipeline about 12% of the time. Bindings persist for the encoder's lifetime,
// so only changed slots and pipelines are forwarded to the driver.
static bool bindDedup;
// Cluster buffer guard (features/cluster-buffer-guard).
static bool clusterGuard;
// Diagnostics: binds that repeat the encoder's current binding.
static bool redundantProbe;
enum RedundantCount { TextureCalls, TextureCallsRedundant, TextureSlots, TextureSlotsRedundant,
    BufferBinds, BufferBindsRedundant, PipelineBinds, PipelineBindsRedundant, DepthBinds, DepthBindsRedundant, RedundantCounts };
static std::atomic<uint64_t> redundantCounts[RedundantCounts];
// Bound buffers, textures and the pipeline are not retained
// here: the encoder (from a retained-references command buffer; see
// commandBuffer) keeps everything bound to it alive until it ends, and BG3 keeps
// its pipeline states. That avoids a retain/release pair on every bind.
struct ConstantBinding { __unsafe_unretained id<MTLBuffer> buffer; NSUInteger offset; NSUInteger length; bool hasBytes; };
static constexpr NSUInteger EncoderSlots = 32;
// BG3's composition draw call, replayed for the generated frame.
struct CompositionDraw {
    MTLPrimitiveType type; NSUInteger start, count, instances, baseInstance; NSInteger baseVertex;
    __unsafe_unretained id<MTLBuffer> indexBuffer; NSUInteger indexOffset; MTLIndexType indexType;
};
@interface BG3MFXEncoderState : NSObject {
@public
    ConstantBinding constants[3][EncoderSlots];
    __unsafe_unretained id<MTLTexture> textures[EncoderSlots];
    __unsafe_unretained id pipeline;
    __strong NSDictionary *description;  // diagnostics may create one per pipeline set
    PipelineKind kind;
    __strong id<MTLCommandBuffer> buffer;
    // setBytes data by stage*EncoderSlots+index; rare, so the binding table
    // itself owns nothing and costs nothing to destroy (one per encoder).
    __strong NSMutableDictionary<NSNumber *, NSData *> *bytes;
    __strong id<MTLTexture> colorTarget;
    __unsafe_unretained id sampler0;
    int mode;            // command buffer's scaling mode; -1 when unknown
    bool lastDrawOther;  // the latest draw used an unrecognized pipeline
    // BG3's viewport and scissor, replayed for the generated composition.
    bool hasViewport, hasScissor;
    MTLViewport viewport;
    MTLScissorRect scissor;
    // Prepass trim: the bound pipeline's class, this pass's role, and BG3's
    // current depth-stencil state (held unretained, like the pipeline).
    BG3MFXPrepassState prepass;
#ifndef BG3MFX_NO_TRACE
    // Diagnostics (BG3MFX_TRACE_REDUNDANT=1): every binding BG3 has made in
    // this encoder, to count binds that repeat what is already bound.
    __unsafe_unretained id seenTexture[64];
    __unsafe_unretained id seenBuffer[2][32];
    NSUInteger seenOffset[2][32];
    __unsafe_unretained id seenPipeline, seenDepth;
    // Cluster buffer guard: what compute indices 1 and 6 hold.
    __unsafe_unretained id clusterSlot[2];
#endif
    // Bind dedup: fragment textures this encoder has actually forwarded.
    BG3MFXBindFilter bindFilter;
    // Per-encoder associated objects our code has set (EncoderAssociation
    // bits; only ever accumulate), so encoder setup and end skip the others.
    uint16_t associations;
    // Lab mode only (see labPoll): the bound pipeline's name, whether its draws
    // are skipped, and this encoder's entry while a frame census is recorded.
    bool labSkip, labWatch, labPoke;
    __unsafe_unretained NSString *labPipeline;
    __strong NSMutableDictionary *labRecord;
}
@end
@implementation BG3MFXEncoderState
- (instancetype)init { if ((self=[super init])) mode=-1; return self; }
@end
// Everything a pipeline bind needs, classified once at creation: one
// associated-object lookup per setRenderPipelineState instead of three.
@interface BG3MFXPipelineInfo : NSObject {
@public
    __strong NSDictionary *description;
    PipelineKind kind;
    TrimPipeline trim;
}
@end
// BG3 binds about 960 pipelines per frame from a few hundred long-lived ones.
// A small per-thread cache avoids the associated-object lookup. Each info is
// an associated object of its pipeline, so it is released exactly when the
// pipeline is: its dealloc, like every hooked pipeline creation, bumps the
// generation. A cache entry therefore never outlives its pipeline, even if
// the address is reused by a pipeline created through a path we do not hook.
static std::atomic<unsigned> pipelineGeneration{1};
@implementation BG3MFXPipelineInfo
- (void)dealloc { pipelineGeneration.fetch_add(1, std::memory_order_release); }
@end
struct PipelineCacheEntry { const void *pipeline; void *info; unsigned generation; };
struct OriginalCacheEntry { Class cls; SEL selector; IMP imp; unsigned generation; };
// Every per-thread hook cache lives in one thread-local block, so a hooked
// call resolves one thread-local address (a _tlv_get_addr call) instead of
// one per cache. Nothing in it is shared between threads.
struct HookThreadCache {
    const void *encoder;          // last encoder looked up and its state
    void *state;
    unsigned encoderGeneration;   // encoderGeneration when it was cached
    PipelineCacheEntry pipelines[64];
    OriginalCacheEntry originals[256];
};
static thread_local HookThreadCache hookCache;
static inline void *pipelineInfoPointer(__unsafe_unretained id state) {
    unsigned generation = pipelineGeneration.load(std::memory_order_acquire);
    PipelineCacheEntry &entry = hookCache.pipelines[((uintptr_t)(__bridge const void *)state >> 4) & 63];
    if (entry.pipeline == (__bridge const void *)state && entry.generation == generation)
        return entry.info;
    __unsafe_unretained BG3MFXPipelineInfo *info = objc_getAssociatedObject(state, &pipelineKey);
    entry = {(__bridge const void *)state, (__bridge void *)info, generation};
    return (__bridge void *)info;
}
static char encoderStateKey;
// Encoders are used one at a time on a thread, so remember the last lookup.
// instrumentEncoder refreshes and endEncoder clears it on its own thread. Any
// thread's instrumentEncoder may release a state (or follow an encoder's
// dealloc at a reused address), so it bumps this generation and every other
// thread's cached state is looked up again: an encoder ended on another
// thread and then recycled never returns a freed state.
static std::atomic<unsigned> encoderGeneration{1};
// Returns a plain pointer: ARC would otherwise retain and release the state
// around every hooked call. The encoder keeps its state alive; callers hold it
// unretained through the encoderState macro below.
static inline __attribute__((always_inline)) void *encoderStatePointer(__unsafe_unretained id encoder) {
    if (!encoder) return nullptr;
    HookThreadCache &cache = hookCache;
    unsigned generation = encoderGeneration.load(std::memory_order_acquire);
    if ((__bridge const void *)encoder == cache.encoder && generation == cache.encoderGeneration) return cache.state;
    __unsafe_unretained BG3MFXEncoderState *state = objc_getAssociatedObject(encoder,&encoderStateKey);
    cache.encoder = (__bridge const void *)encoder; cache.state = (__bridge void *)state; cache.encoderGeneration = generation;
    return (__bridge void *)state;
}
#define encoderState(encoder) ((__bridge BG3MFXEncoderState *)encoderStatePointer(encoder))
enum EncoderAssociation : uint16_t {
    AssocTAAInputs = 1, AssocFSRInputs = 2, AssocComposition = 4, AssocPostprocess = 8,
    AssocSuppressed = 16, AssocBindings = 32, AssocAttachments = 64, AssocWaterfall = 128, AssocAll = 0xffff,
};
static inline void noteAssociation(__unsafe_unretained id encoder, uint16_t bit) {
    if (__unsafe_unretained BG3MFXEncoderState *s = encoderState(encoder)) s->associations |= bit;
}
// An encoder without our state may carry anything: treat every key as set.
static inline uint16_t encoderAssociations(__unsafe_unretained BG3MFXEncoderState *s) { return s ? s->associations : AssocAll; }
static void forgetEncoder(id encoder) {
    if ((__bridge const void *)encoder == hookCache.encoder) { hookCache.encoder = nullptr; hookCache.state = nullptr; }
}
// Encoders from paths not instrumented have no state; field reads through a
// nil object pointer would crash, unlike messages to nil.
static id<MTLCommandBuffer> encoderBuffer(id encoder) { __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder); return s ? s->buffer : nil; }
static id<MTLTexture> encoderTarget(id encoder) { __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder); return s ? s->colorTarget : nil; }
static NSDictionary *pipelineDescription(id encoder) { __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder); return s ? s->description : nil; }
static id encoderPipeline(id encoder) { __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder); return s ? s->pipeline : nil; }
static id encoderSampler(id encoder) { __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder); return s ? s->sampler0 : nil; }
static void setEncoderMode(id encoder, NSNumber *mode) {
    if (__unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder)) s->mode=mode ? mode.intValue : -1;
}
static int encoderScalingMode(__unsafe_unretained id encoder) {
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder);
    return s && s->mode>=0 ? s->mode : BG3MFXSelectedScalingMode();
}
// Bound textures by index, as a dictionary for the few recognized passes.
static NSDictionary *boundTextures(id encoder) {
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder);
    if (!s) return nil;
    NSMutableDictionary *textures=[NSMutableDictionary dictionary];
    for (NSUInteger i=0;i<EncoderSlots;++i) if (s->textures[i]) textures[@(i).stringValue]=s->textures[i];
    return textures;
}
// BG3 composes scene and UI with CombineUI, or CombineUI_HDR when HDR output
// is enabled; both take the same scene, UI, constants and sampler bindings.
static BOOL compositionShader(NSString *fragment) {
    return [fragment isEqualToString:@"CombineUI"] || [fragment isEqualToString:@"CombineUI_HDR"];
}
// BG3's UI model VFX alpha-blend a 3D effect straight onto the final scene image.
static BOOL sceneOverlayShader(NSString *fragment) { return [fragment hasPrefix:@"Shared_UI_VFX_UI_Model_"]; }
// BG3 grades colors in place on the TAA output when bloom is off (the read is the TAA input).
static BOOL colorGradingShader(NSString *fragment) { return [fragment isEqualToString:@"PPColorGradingApplyLUTPS"]; }
// Passes that rewrite a tagged scene image in place, keeping its frame inputs.
static BOOL inPlaceScenePass(NSString *fragment) { return colorGradingShader(fragment) || sceneOverlayShader(fragment); }
static PipelineKind classifyPipeline(NSString *fragment) {
    if ([fragment isEqualToString:@"PPTAA_PS"]) return PipelineTAA;
    if ([fragment isEqualToString:@"LinearizeDepth"]) return PipelineLinearizeDepth;
    if ([fragment isEqualToString:@"VelocityBufferCamera_PS"]) return PipelineVelocity;
    if ([fragment isEqualToString:@"PPToneMap_LUT"]) return PipelineToneMapLUT;
    if (compositionShader(fragment)) return PipelineCombineUI;
    if ([fragment isEqualToString:@"PPBloomUpsampleBlurAndCombine_PS"] || [fragment isEqualToString:@"PPColorGradingApplyLUTPS"] ||
        [fragment isEqualToString:@"EoCOutlineCombinePS"] || [fragment isEqualToString:@"EoCSight"] || [fragment isEqualToString:@"FSR_Tonemap"]) return PipelinePostColor;
    if (sceneOverlayShader(fragment)) return PipelineSceneOverlay;
    return PipelineOther;
}
static bool temporalInputsNeeded(__unsafe_unretained id encoder) {
    (void)encoder;
    return diagnostics || metalFXEnabled;
}
static bool labEnabled;
static bool constantInputNeeded(__unsafe_unretained id encoder, NSUInteger index) {
    return index < 32 && (diagnostics || labEnabled || (temporalInputsNeeded(encoder) && (index == 0 || index == 8 || index == 9 || index == 11)));
}
static NSUInteger sceneProbeAttempts;
static char deviceDepthKey, sceneCaptureFailureKey, sceneCameraKey, taaInputsKey;
static char fsrInputsKey, nativeFallbackKey;
// A frame whose FSR input matches no captured scene (loading, view or size
// transitions) runs BG3's native FSR instead of closing the game. Temporal
// history restarts on the next MetalFX frame.
static std::atomic<bool> temporalResetPending{false};
#ifndef BG3MFX_NO_TRACE
static void record(NSDictionary *event);
#endif
static void fallBackToNative(id encoder, BOOL temporal, NSString *reason) {
    objc_setAssociatedObject(encoder,&nativeFallbackKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (temporal) temporalResetPending=true;
    static std::atomic<unsigned> fallbacks{0};
    unsigned count=++fallbacks;
    if (count==1 || count%600==0) {
        fprintf(stderr,"MetalFX %s used native FSR for a frame (%u so far): %s\n",
            temporal ? "Temporal" : "Spatial",count,reason.UTF8String);
        fflush(stderr);
    }
    record(@{@"event":@"metalFXNativeFallback",@"temporal":@(temporal),@"reason":reason ?: @"",@"count":@(count)});
    if (count <= 20 || count%300 == 0) labRecord(@{@"event":@"metalFXNativeFallback",@"temporal":@(temporal),@"reason":reason ?: @"",@"count":@(count)});
}
static char temporalFrameKey, temporalSuppressedKey;
// Only replace AA on exact targets already observed feeding native FSR.
// Auxiliary views (inventory, portraits) must keep AA if they do not upscale.
// Weak identities neither keep obsolete render targets alive nor match a new
// allocation that happens to reuse an old address.
static NSHashTable *upscaledTAATargets() {
    static NSHashTable *targets = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
    return targets;
}
static BOOL knownUpscaledTAA(id<MTLTexture> target) {
    std::lock_guard<std::recursive_mutex> lock(guard());
    return target && [upscaledTAATargets() containsObject:target];
}
static void rememberUpscaledTAA(id<MTLTexture> target) {
    if (!target) return;
    std::lock_guard<std::recursive_mutex> lock(guard());
    [upscaledTAATargets() addObject:target];
}
static char temporalPostprocessKey;
static BOOL temporalColorPass(NSString *name) {
    return [name isEqualToString:@"PPBloomUpsampleBlurAndCombine_PS"] ||
        [name isEqualToString:@"PPColorGradingApplyLUTPS"] ||
        [name isEqualToString:@"EoCOutlineCombinePS"] ||
        [name isEqualToString:@"EoCSight"] ||  // stealth/visibility overlay, ping-pongs a variable number of times
        [name isEqualToString:@"FSR_Tonemap"];
}
// Quiet runtime: pipelines keep their fragment name only when the integration reads it.
static BOOL recognizedFragment(NSString *fragment) {
    return [fragment isEqualToString:@"PPTAA_PS"] || [fragment isEqualToString:@"LinearizeDepth"] || [fragment isEqualToString:@"VelocityBufferCamera_PS"] ||
        temporalColorPass(fragment) || compositionShader(fragment) || [fragment isEqualToString:@"PPToneMap_LUT"] || sceneOverlayShader(fragment);
}
#ifndef BG3MFX_NO_TRACE
static char temporalPassHistoryKey;
#endif
static BOOL spatialFailed;
static BOOL temporalFailed;
static std::atomic<unsigned> originalsGeneration{1};
static IMP originalSlow(Class concrete, SEL selector, unsigned generation, OriginalCacheEntry &entry);
// The original implementation of a hooked method, from this thread's cache.
static inline __attribute__((always_inline)) IMP original(__unsafe_unretained id object, SEL selector) {
    Class concrete = object_getClass(object);
    unsigned generation = originalsGeneration.load(std::memory_order_acquire);
    OriginalCacheEntry &entry = hookCache.originals[((uintptr_t)concrete >> 4 ^ (uintptr_t)selector >> 2) & 255];
    if (entry.cls == concrete && entry.selector == selector && entry.generation == generation) return entry.imp;
    return originalSlow(concrete, selector, generation, entry);
}

static EncoderStage bindingStage(SEL cmd) {
    static SEL vertex[]={@selector(setVertexBuffer:offset:atIndex:),@selector(setVertexBuffers:offsets:withRange:),
        @selector(setVertexBufferOffset:atIndex:),@selector(setVertexBytes:length:atIndex:)};
    static SEL fragment[]={@selector(setFragmentBuffer:offset:atIndex:),@selector(setFragmentBuffers:offsets:withRange:),
        @selector(setFragmentBufferOffset:atIndex:),@selector(setFragmentBytes:length:atIndex:)};
    for (SEL v:vertex) if (cmd==v) return StageVertex;
    for (SEL f:fragment) if (cmd==f) return StageFragment;
    return StageCompute;
}
static ConstantBinding *constantSlot(__unsafe_unretained id encoder, EncoderStage stage, NSUInteger index) {
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder);
    return s && index<EncoderSlots ? &s->constants[stage][index] : nullptr;
}
// Dictionary view ("fragment:8" -> buffer/offset or bytes/length), diagnostics only.
static NSMutableDictionary *constantBindings(id encoder) {
    NSMutableDictionary *bindings=[NSMutableDictionary dictionary];
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder);
    static NSString *const stages[]={@"vertex",@"fragment",@"compute"};
    if (s) for (int stage=0;stage<3;++stage) for (NSUInteger i=0;i<EncoderSlots;++i) {
        ConstantBinding &b=s->constants[stage][i];
        NSString *slot=[NSString stringWithFormat:@"%@:%lu",stages[stage],(unsigned long)i];
        NSData *data=b.hasBytes ? s->bytes[@(stage*EncoderSlots+i)] : nil;
        if (data) bindings[slot]=@{@"bytes":data,@"length":@(b.length)};
        else if (b.buffer) bindings[slot]=@{@"buffer":b.buffer,@"offset":@(b.offset)};
    }
    return bindings;
}
// Diagnostics: count binds that repeat the encoder's current binding. Called
// before forwarding; compute bindings are not counted.
static void countBuffers(__unsafe_unretained id self, SEL cmd, id<MTLBuffer> const *buffers, const NSUInteger *offsets, NSRange range, bool offsetOnly) {
#ifdef BG3MFX_NO_TRACE
    (void)self; (void)cmd; (void)buffers; (void)offsets; (void)range; (void)offsetOnly;
#else
    if (!diagnostics || !redundantProbe) return;
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(self);
    EncoderStage stage=bindingStage(cmd);
    if (!s || stage==StageCompute) return;
    for (NSUInteger i=0; i<range.length; ++i) {
        NSUInteger index=range.location+i;
        if (index>=32) continue;
        __unsafe_unretained id buffer=offsetOnly ? s->seenBuffer[stage][index] : buffers[i];
        bool same=buffer && s->seenBuffer[stage][index]==buffer && s->seenOffset[stage][index]==offsets[i];
        ++redundantCounts[BufferBinds];
        if (same) ++redundantCounts[BufferBindsRedundant];
        s->seenBuffer[stage][index]=buffer; s->seenOffset[stage][index]=offsets[i];
    }
#endif
}
static void countTextures(__unsafe_unretained id self, SEL cmd, id<MTLTexture> const *textures, NSRange range) {
#ifdef BG3MFX_NO_TRACE
    (void)self; (void)cmd; (void)textures; (void)range;
#else
    if (!diagnostics || !redundantProbe) return;
    static SEL one=@selector(setFragmentTexture:atIndex:), many=@selector(setFragmentTextures:withRange:);
    if (cmd!=one && cmd!=many) return;
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(self);
    if (!s) return;
    bool callSame=true;
    for (NSUInteger i=0; i<range.length; ++i) {
        NSUInteger index=range.location+i;
        bool same=index<64 && s->seenTexture[index]==textures[i];
        ++redundantCounts[TextureSlots];
        if (same) ++redundantCounts[TextureSlotsRedundant]; else callSame=false;
        if (index<64) s->seenTexture[index]=textures[i];
    }
    ++redundantCounts[TextureCalls];
    if (callSame) ++redundantCounts[TextureCallsRedundant];
#endif
}
static void flushRedundantCounts() {
    static unsigned long lastFrame;
    if (!diagnostics || !redundantProbe || frames-lastFrame<120) return;
    [[maybe_unused]] double n=(double)(frames-lastFrame);
    lastFrame=frames;
    uint64_t c[RedundantCounts];
    for (int i=0; i<RedundantCounts; ++i) c[i]=redundantCounts[i].exchange(0);
    record(@{@"event":@"redundantBinds",@"frame":@(frames),
        @"textureCallsPerFrame":@(c[TextureCalls]/n),@"textureCallsRedundant":@(c[TextureCallsRedundant]/n),
        @"textureSlotsPerFrame":@(c[TextureSlots]/n),@"textureSlotsRedundant":@(c[TextureSlotsRedundant]/n),
        @"bufferBindsPerFrame":@(c[BufferBinds]/n),@"bufferBindsRedundant":@(c[BufferBindsRedundant]/n),
        @"pipelineBindsPerFrame":@(c[PipelineBinds]/n),@"pipelineBindsRedundant":@(c[PipelineBindsRedundant]/n),
        @"depthBindsPerFrame":@(c[DepthBinds]/n),@"depthBindsRedundant":@(c[DepthBindsRedundant]/n)});
}
// Diagnostics: which buffer BG3 leaves at the cluster indices of a compute
// encoder, so dispatches show whether the guard's stand-in was read. Recorded by
// the compute binding hooks below, which also track constants.
#ifndef BG3MFX_NO_TRACE
static void noteClusterSlot(__unsafe_unretained id encoder, SEL cmd, NSUInteger index, __unsafe_unretained id buffer) {
    if (!diagnostics || !clusterGuard || bindingStage(cmd) != StageCompute) return;
    int slot = index == BG3MFXClusterInfoIndex ? 0 : index == BG3MFXClusterInfoWriteIndex ? 1 : -1;
    if (slot < 0) return;
    if (__unsafe_unretained BG3MFXEncoderState *s = encoderState(encoder)) s->clusterSlot[slot] = buffer;
}
#else
static void noteClusterSlot(id, SEL, NSUInteger, id) {}
#endif
static void bindBuffer(__unsafe_unretained id self, SEL cmd, __unsafe_unretained id<MTLBuffer> buffer, NSUInteger offset, NSUInteger index) {
    if (diagnostics && redundantProbe) { id<MTLBuffer> const one[1]={buffer}; countBuffers(self,cmd,one,&offset,NSMakeRange(index,1),false); }
    ((void(*)(id,SEL,id,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,buffer,offset,index);
    noteClusterSlot(self,cmd,index,buffer);
    if (!constantInputNeeded(self,index)) return;
    if (ConstantBinding *b=constantSlot(self,bindingStage(cmd),index)) { b->buffer=buffer; b->offset=offset; b->hasBytes=false; b->length=0; }
}
static void bindBuffers(__unsafe_unretained id self, SEL cmd, id<MTLBuffer> const *buffers, const NSUInteger *offsets, NSRange range) {
    countBuffers(self,cmd,buffers,offsets,range,false);
    ((void(*)(id,SEL,id<MTLBuffer> const *,const NSUInteger *,NSRange))original(self,cmd))(self,cmd,buffers,offsets,range);
    for (NSUInteger i=0; i<range.length; ++i) noteClusterSlot(self,cmd,range.location+i,buffers[i]);
    if (!temporalInputsNeeded(self) && !labEnabled) return;
    EncoderStage stage=bindingStage(cmd);
    for (NSUInteger i=0; i<range.length; ++i) {
        if (!constantInputNeeded(self,range.location+i)) continue;
        if (ConstantBinding *b=constantSlot(self,stage,range.location+i)) { b->buffer=buffers[i]; b->offset=offsets[i]; b->hasBytes=false; b->length=0; }
    }
}
#ifndef BG3MFX_NO_TRACE
// The passes Metal validation reported without ClusterInfoBuffer;
// VolumetricFogGather and the debug views don't declare it.
static BOOL clusterPass(NSString *name) {
    return ([name hasPrefix:@"ClusteredLighting_"] && ![name hasPrefix:@"ClusteredLighting_Debug"])
        || [name isEqualToString:@"VolumetricFogInitialize"] || [name isEqualToString:@"VolumetricFogLighting"]
        || [name isEqualToString:@"ClusterAssignment"];
}
// Reports cluster passes that read the stand-in (BG3 left the slot unbound) or
// an explicit nil (which the guard cannot cover): the first few, then every 256th.
static void noteClusterDispatch(__unsafe_unretained id encoder, NSString *name) {
    if (!clusterGuard || !clusterPass(name)) return;
    __unsafe_unretained BG3MFXEncoderState *s = encoderState(encoder);
    if (!s) return;
    int slot = [name isEqualToString:@"ClusterAssignment"] ? 1 : 0;
    __unsafe_unretained id bound = s->clusterSlot[slot];
    bool standIn = BG3MFXIsClusterStandIn(bound);
    if (!standIn && bound) return;
    static std::atomic<unsigned> standIns{0}, nils{0};
    unsigned count = standIn ? ++standIns : ++nils;
    if (count <= 8 || count % 256 == 0)
        record(@{@"event":@"clusterBufferGuard",@"pipeline":name,@"bound":standIn ? @"standIn" : @"nil",
            @"count":@(count),@"frame":@(BG3MFXRenderedFrames.load())});
}
#endif
static void bufferOffset(__unsafe_unretained id self, SEL cmd, NSUInteger offset, NSUInteger index) {
    if (diagnostics && redundantProbe) countBuffers(self,cmd,nullptr,&offset,NSMakeRange(index,1),true);
    ((void(*)(id,SEL,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,offset,index);
    if (!constantInputNeeded(self,index)) return;
    if (ConstantBinding *b=constantSlot(self,bindingStage(cmd),index)) if (b->buffer) b->offset=offset;
}
static void bindBytes(__unsafe_unretained id self, SEL cmd, const void *bytes, NSUInteger length, NSUInteger index) {
    ((void(*)(id,SEL,const void *,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,bytes,length,index);
    noteClusterSlot(self,cmd,index,bytes && length ? (id)kCFNull : nil);  // any non-nil marker: BG3 filled the slot
    if (!constantInputNeeded(self,index)) return;
    EncoderStage stage=bindingStage(cmd);
    if (ConstantBinding *b=constantSlot(self,stage,index)) {
        __unsafe_unretained BG3MFXEncoderState *s=encoderState(self);
        b->buffer=nil; b->offset=0; b->hasBytes=bytes && length; b->length=b->hasBytes ? length : 0;
        if (b->hasBytes) {
            if (!s->bytes) s->bytes=[NSMutableDictionary dictionary];
            s->bytes[@(stage*EncoderSlots+index)]=[NSData dataWithBytes:bytes length:MIN(length,4096)];
        }
        // Lab census: keep every setBytes payload as bound, in binding order.
        if (labEnabled && s && s->labRecord && b->hasBytes) {
            static NSString *const names[]={@"vertex",@"fragment",@"compute"};
            NSString *key=[NSString stringWithFormat:@"%@:%lu",names[stage],(unsigned long)index];
            NSString *data=[[NSData dataWithBytes:bytes length:MIN(length,1024)] base64EncodedStringWithOptions:0];
            std::lock_guard<std::recursive_mutex> lock(guard());
            NSMutableArray *log=s->labRecord[@"setBytes"];
            if (!log) s->labRecord[@"setBytes"]=log=[NSMutableArray array];
            if (log.count<64) [log addObject:@{@"slot":key,@"length":@(length),@"base64":data ?: @""}];
        }
    }
}
#ifndef BG3MFX_NO_TRACE
static void record(NSDictionary *event) {
    std::lock_guard<std::recursive_mutex> lock(guard());
    NSString *kind = event[@"event"];
    BOOL shadowEvent = NO;
    BOOL important = shadowEvent || [kind hasPrefix:@"nativeMenu"] || [kind isEqualToString:@"nativeUpscalingApplied"] ||
        [kind isEqualToString:@"nativeQualityChanged"] || [kind hasPrefix:@"waterfall"] ||
        [kind isEqualToString:@"upscalingModeChanged"] || [kind isEqualToString:@"metalHUDChanged"] ||
        [kind isEqualToString:@"temporalValidationProgress"] || [kind isEqualToString:@"temporalScalerCreated"] || [kind hasPrefix:@"frameGeneration"] || [kind isEqualToString:@"nativeMenuOption"] ||
[kind isEqualToString:@"prepassTrim"] || [kind hasPrefix:@"cullTiming"] || [kind isEqualToString:@"redundantBinds"] ||
        [kind hasPrefix:@"threadIdling"] || [kind hasPrefix:@"dynamicWorkers"] || [kind hasPrefix:@"luaJumpFix"] ||
        [kind isEqualToString:@"metal4Residency"] || [kind isEqualToString:@"clusterBufferGuard"];
    if (!output || (!important && seen.count >= 20000 &&
        ![event[@"event"] isEqualToString:@"spatialUpscaleError"] &&
        ![event[@"event"] isEqualToString:@"temporalUpscaleError"])) return;
    NSMutableDictionary *identified = [event mutableCopy];
    identified[@"pid"] = @(getpid());
    if (important) identified[@"time"] = @(NSDate.timeIntervalSinceReferenceDate);
    NSData *data = [NSJSONSerialization dataWithJSONObject:identified options:NSJSONWritingSortedKeys error:nil];
    if (!data) return;
    // Important events carry a timestamp, so each is unique: remembering them
    // grew the set by one entry per frame with Frame Generation or prepass trim.
    if (!important) {
        NSString *key = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if ([seen containsObject:key]) return;
        [seen addObject:key];
    }
    NSMutableData *line = [data mutableCopy];
    [line appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [output writeData:line];
}
#endif
// Lab mode: a rendering investigation aid, off unless BG3MFX_LAB names a
// directory. Its control.txt is reread a few times a second. Each "skip <text>"
// line drops the draws and dispatches of every shader whose name contains
// <text>; a changed "census <name>" line records the next frame's passes to
// census-<name>.json, and "watch <text>" lines add the bound textures, constant
// buffers, viewport and grid of matching calls to it. "poke <text> <index>
// <offset> <float>" rebinds a matching dispatch's compute buffer <index> as a
// copy with that float written at <offset>, then restores the original binding.
// A "serialize" line chains every render and compute encoder with a fence, so
// no pass can overlap the one before it (a test for missing synchronization).
// "dump <tag> <text> <slot>" (a new tag each time) copies the texture bound at
// <slot> of the next matching call, as it is when that command buffer ends, to
// dump-<tag>.raw with a dump-<tag>.json description. "dumpbuf <tag> <text>
// <index> <length>" does the same for the compute buffer bound at <index>. status.json reports what the game applied,
// so a screenshot can be matched to the skips in effect.
static NSString *labDirectory;
static char labNameKey, labRulesKey;
static NSArray<NSString *> *labSkips, *labWatches;
static NSArray<NSDictionary *> *labPokes;
static std::atomic<bool> labSerialize{false};
static NSMutableArray<NSMutableDictionary *> *labDumps;  // armed, captured or written requests
static std::atomic<bool> labDumpArmed{false}, labDumpCaptured{false};
static id<MTLFence> labFence(id<MTLDevice> device) {
    static id<MTLFence> fence;
    std::lock_guard<std::recursive_mutex> lock(guard());
    if (!fence && device) fence = [device newFence];
    return fence;
}
static std::atomic<unsigned> labGeneration{1};
// "scaling N" renders new command buffers as Upscaling Type N (1 FSR, 2 Spatial,
// 3 Temporal) for same-scene comparisons; GPU time feeds perf.json.
static std::atomic<int> labScaling{-1};
static std::atomic<uint64_t> labGPUNanoseconds{0}, labCommits{0}, labMetal4Nanoseconds{0};
// Metal 4 bridge submissions (MetalFX Temporal on Metal 4) run outside BG3's
// command buffers, which only wait for them; their own GPU time, for perf.json.
static void labMetal4Timing(NSString *, double seconds) {
    if (seconds > 0 && seconds < 1) labMetal4Nanoseconds.fetch_add((uint64_t)(seconds*1e9),std::memory_order_relaxed);
}
enum LabCensus : uint8_t { LabIdle, LabArmed, LabRecording };
static LabCensus labCensus;
static NSString *labCensusName;
static NSMutableArray *labFrame;
static void labWrite(NSString *file, id object);
// "profile <name>": a census whose render and compute passes also carry GPU
// timestamps at stage boundaries; once the GPU has finished that frame,
// profile-<name>.json lists every pass with its GPU time.
static bool labProfileRequested, labProfiling;
static id<MTLCounterSampleBuffer> labCounters;
static id<MTLDevice> labProfileDevice;
static NSUInteger labSamples;
static const NSUInteger labSampleLimit = 4096;
static MTLTimestamp labProfileCPU, labProfileGPU;
static thread_local bool labCreatingProfiledEncoder;
// The first of two samples (start, end) for the next profiled pass, or NSNotFound.
static NSUInteger labProfileSamples(id<MTLDevice> device) {
    if (!labProfiling || !device) return NSNotFound;
    std::lock_guard<std::recursive_mutex> lock(guard());
    if (!labCounters) {
        id<MTLCounterSet> timestamps = nil;
        for (id<MTLCounterSet> set in device.counterSets) if ([set.name isEqualToString:MTLCommonCounterSetTimestamp]) timestamps = set;
        MTLCounterSampleBufferDescriptor *desc = [MTLCounterSampleBufferDescriptor new];
        desc.counterSet = timestamps; desc.storageMode = MTLStorageModeShared; desc.sampleCount = labSampleLimit;
        if (timestamps && [device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary])
            labCounters = [device newCounterSampleBufferWithDescriptor:desc error:nil];
        labProfileDevice = device;
        if (!labCounters) { labProfiling = false; fprintf(stderr,"BG3 MetalFX lab: GPU timestamps unavailable\n"); return NSNotFound; }
    }
    if (device != labProfileDevice || labSamples + 2 > labSampleLimit) return NSNotFound;
    if (!labSamples) [device sampleTimestamps:&labProfileCPU gpuTimestamp:&labProfileGPU];
    NSUInteger first = labSamples; labSamples += 2;
    return first;
}
static id labProfiledComputeEncoder(id<MTLCommandBuffer> buffer, MTLDispatchType type, NSUInteger samples) {
    MTLComputePassDescriptor *pass = [MTLComputePassDescriptor computePassDescriptor];
    pass.dispatchType = type;
    pass.sampleBufferAttachments[0].sampleBuffer = labCounters;
    pass.sampleBufferAttachments[0].startOfEncoderSampleIndex = samples;
    pass.sampleBufferAttachments[0].endOfEncoderSampleIndex = samples + 1;
    labCreatingProfiledEncoder = true;
    id encoder = [buffer computeCommandEncoderWithDescriptor:pass];
    labCreatingProfiledEncoder = false;
    return encoder;
}
// MetalFX's own Metal 4 GPU time per frame from the latest perf.json, for profiles.
static std::atomic<double> labMetal4MsPerFrame{0};
static void labWriteProfile(NSArray<NSMutableDictionary *> *frame, NSUInteger count, NSString *name) {
    NSData *data = count ? [labCounters resolveCounterRange:NSMakeRange(0,count)] : nil;
    const MTLCounterResultTimestamp *samples = (const MTLCounterResultTimestamp *)data.bytes;
    MTLTimestamp cpu = 0, gpu = 0;
    [labProfileDevice sampleTimestamps:&cpu gpuTimestamp:&gpu];
    double nanosecondsPerTick = gpu > labProfileGPU ? (double)(cpu - labProfileCPU) / (double)(gpu - labProfileGPU) : 1;
    NSMutableArray *passes = [NSMutableArray array];
    double total = 0;
    for (NSDictionary *entry in frame) {
        NSNumber *first = entry[@"samples"];
        if (!first || !samples || first.unsignedIntegerValue + 1 >= count + 1) continue;
        uint64_t start = samples[first.unsignedIntegerValue].timestamp, end = samples[first.unsignedIntegerValue + 1].timestamp;
        if (start == MTLCounterErrorValue || end == MTLCounterErrorValue || !start || end < start) continue;
        double ms = (end - start) * nanosecondsPerTick * 1e-6;
        total += ms;
        NSMutableDictionary *pass = [@{@"index":entry[@"index"],@"kind":entry[@"kind"],@"gpuMs":@(ms),
            @"draws":entry[@"draws"] ?: @{},@"dispatches":entry[@"dispatches"] ?: @{}} mutableCopy];
        if (entry[@"viewport"]) pass[@"viewport"] = entry[@"viewport"];
        if (entry[@"label"]) pass[@"label"] = entry[@"label"];
        if (entry[@"colors"]) pass[@"colors"] = entry[@"colors"];
        [passes addObject:pass];
    }
    labWrite([NSString stringWithFormat:@"profile-%@.json",name],@{@"profile":name,@"passes":passes,@"sumMs":@(total),
        @"metal4MsPerFrame":@(labMetal4MsPerFrame.load())});
    fprintf(stderr,"BG3 MetalFX lab: profile %s timed %lu passes, %.2f ms in total\n",name.UTF8String,(unsigned long)passes.count,total);
}
// Lab mode: the upscaling pipeline's diagnostic events, in input-log.jsonl.
// Most of them come every frame: the first 300 of each kind (per split-screen
// view) are kept, then every 300th, with its count.
static void labRecordEvent(NSDictionary *event) {
    static std::mutex lock;
    static NSMutableDictionary<NSString *,NSNumber *> *counts = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%@ %@",event[@"event"],[event[@"view"] componentsJoinedByString:@","]];
    NSUInteger count;
    {
        std::lock_guard<std::mutex> hold(lock);
        count = counts[key].unsignedIntegerValue + 1;
        counts[key] = @(count);
    }
    if (count > 300 && count % 300) return;
    if (count <= 300) { BG3MFXLabInputNote(event); return; }
    NSMutableDictionary *counted = [event mutableCopy];
    counted[@"count"] = @(count);
    BG3MFXLabInputNote(counted);
}
static NSMutableDictionary *labLayouts;  // render pipeline name -> vertex descriptor
static void labTagPipeline(id state, NSString *name, MTLVertexDescriptor *vertex = nil) {
    if (!labEnabled || !state || !name.length) return;
    objc_setAssociatedObject(state,&labNameKey,name,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!vertex) return;
    NSMutableArray *attributes = [NSMutableArray array], *layouts = [NSMutableArray array];
    for (NSUInteger i = 0; i < 31; ++i) {
        MTLVertexAttributeDescriptor *a = vertex.attributes[i];
        if (a.format != MTLVertexFormatInvalid)
            [attributes addObject:@{@"index":@(i),@"format":@(a.format),@"offset":@(a.offset),@"buffer":@(a.bufferIndex)}];
        MTLVertexBufferLayoutDescriptor *l = vertex.layouts[i];
        if (l.stride) [layouts addObject:@{@"buffer":@(i),@"stride":@(l.stride),@"step":@(l.stepFunction),@"rate":@(l.stepRate)}];
    }
    std::lock_guard<std::recursive_mutex> lock(guard());
    if (!labLayouts) labLayouts = [NSMutableDictionary dictionary];
    labLayouts[name] = @{@"attributes":attributes,@"layouts":layouts};
}
static void labWrite(NSString *file, id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
    [data writeToFile:[labDirectory stringByAppendingPathComponent:file] atomically:YES];
}
// "fragment:9", "vertex:0", "compute:3" or a bare compute index.
static bool labStageSlot(NSString *text, EncoderStage *stage, NSUInteger *index) {
    NSArray<NSString *> *parts = [text componentsSeparatedByString:@":"];
    NSString *number = parts.lastObject;
    if (parts.count > 2 || !number.length || [number rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) return false;
    *stage = StageCompute;
    if (parts.count == 2) {
        if ([parts[0] isEqualToString:@"vertex"]) *stage = StageVertex;
        else if ([parts[0] isEqualToString:@"fragment"]) *stage = StageFragment;
        else if (![parts[0] isEqualToString:@"compute"]) return false;
    }
    *index = (NSUInteger)number.integerValue;
    return *index < EncoderSlots;
}
static void labPoll(void) {
    static double lastCheck;
    static NSDate *lastModified;
    static bool first = true;
    double now = NSProcessInfo.processInfo.systemUptime;
    std::lock_guard<std::recursive_mutex> lock(guard());
    if (now - lastCheck < 0.25) return;
    lastCheck = now;
    NSString *path = [labDirectory stringByAppendingPathComponent:@"control.txt"];
    NSDate *modified = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileModificationDate;
    if (!modified) first = false;  // a control file created later is not a launch-time one
    if (!modified || [modified isEqualToDate:lastModified]) return;
    lastModified = modified;
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSMutableArray *skips = [NSMutableArray array], *watches = [NSMutableArray array], *pokes = [NSMutableArray array];
    NSMutableArray *pads = [NSMutableArray array];
    NSString *census = nil;
    bool serialize = false;
    int scaling = -1, sharpen = -1;
    bool profile = false;
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([line hasPrefix:@"skip "] && line.length > 5) [skips addObject:[line substringFromIndex:5]];
        else if ([line hasPrefix:@"watch "] && line.length > 6) [watches addObject:[line substringFromIndex:6]];
        else if ([line isEqualToString:@"serialize"]) serialize = true;
        else if ([line hasPrefix:@"dump "] || [line hasPrefix:@"dumpbuf "]) {
            static NSMutableSet *seenTags = [NSMutableSet set];
            bool buffer = [line hasPrefix:@"dumpbuf "];
            NSMutableArray *words = [[[line substringFromIndex:buffer ? 8 : 5] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet] mutableCopy];
            [words removeObject:@""];
            // An optional last word "#N" picks the Nth matching call of a frame.
            NSUInteger occurrence = 1;
            if (words.count && [words.lastObject hasPrefix:@"#"]) { occurrence = MAX(1,[[words.lastObject substringFromIndex:1] integerValue]); [words removeLastObject]; }
            EncoderStage stage = StageCompute; NSUInteger slot = 0;
            bool color = !buffer && words.count == 3 && [words[2] isEqualToString:@"color0"];
            bool valid = words.count == (buffer ? 4u : 3u) && (color || labStageSlot(words[2],&stage,&slot)) && (buffer || stage == StageCompute);
            if (valid && ![seenTags containsObject:words[0]]) {
                [seenTags addObject:words[0]];
                if (!first) {
                    if (!labDumps) labDumps = [NSMutableArray array];
                    NSMutableDictionary *dump = [@{@"tag":words[0],@"text":words[1],@"slot":@(slot),@"stage":@(stage),@"state":@"armed",
                        @"occurrence":@(occurrence),@"seen":@0} mutableCopy];
                    if (color) dump[@"color"] = @YES;
                    if (buffer) dump[@"length"] = @([words[3] integerValue]);
                    [labDumps addObject:dump];
                    labDumpArmed = true;
                }
            }
        }
        else if ([line hasPrefix:@"poke "]) {
            NSArray *words = [[line substringFromIndex:5] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            // poke <text> <[stage:]index> <offset> <value>; a value "i<N>" writes an integer.
            EncoderStage stage; NSUInteger index;
            if (words.count == 4 && labStageSlot(words[1],&stage,&index)) {
                NSString *value = words[3];
                bool integer = [value hasPrefix:@"i"];
                [pokes addObject:@{@"text":words[0],@"stage":@(stage),@"index":@(index),@"offset":@([words[2] integerValue]),
                    @"integer":@(integer),@"value":integer ? @([[value substringFromIndex:1] intValue]) : @([value floatValue])}];
            }
        }
        else if ([line hasPrefix:@"census "] && line.length > 7) census = [line substringFromIndex:7];
        else if ([line hasPrefix:@"profile "] && line.length > 8) { census = [line substringFromIndex:8]; profile = true; }
        else if ([line hasPrefix:@"scaling "]) scaling = [[line substringFromIndex:8] intValue];
        else if ([line hasPrefix:@"sharpen "]) sharpen = [[line substringFromIndex:8] intValue];
        else if ([line hasPrefix:@"pad "]) [pads addObject:[line substringFromIndex:4]];
    }
    NSArray *padState = BG3MFXLabPadsApply(pads);
    labSkips = skips; labWatches = watches; labPokes = pokes; labSerialize = serialize; labScaling = scaling;
    if (sharpen >= 0) BG3MFXSetSharpeningEnabled(sharpen != 0);
    unsigned generation = ++labGeneration;
    // A census already named in the file at launch is not repeated.
    if (census && !first && ![census isEqualToString:labCensusName]) { labCensus = LabArmed; labProfileRequested = profile; }
    if (census) {
        NSCharacterSet *unsafe = [[NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"] invertedSet];
        labCensusName = [[census componentsSeparatedByCharactersInSet:unsafe] componentsJoinedByString:@"_"];
    }
    first = false;
    labWrite(@"status.json",@{@"generation":@(generation),@"skip":skips,@"watch":watches,@"poke":pokes,@"serialize":@(serialize),@"dumps":@(labDumps.count),@"census":labCensusName ?: @"",@"frame":@(frames),@"scaling":@(scaling),@"pads":padState});
    fprintf(stderr,"BG3 MetalFX lab: generation %u, %lu skip rule(s)%s\n",generation,(unsigned long)skips.count,
        labCensus == LabArmed ? ", census armed" : "");
}
// Skip (bit 0), watch (bit 1) and poke (bit 2) rules for a pipeline, cached
// per control generation.
static unsigned labRules(__unsafe_unretained id state) {
    unsigned generation = labGeneration.load(std::memory_order_acquire);
    NSNumber *cached = objc_getAssociatedObject(state,&labRulesKey);
    if (cached && (cached.unsignedIntValue >> 3) == generation) return cached.unsignedIntValue & 7;
    NSString *name = objc_getAssociatedObject(state,&labNameKey);
    NSArray<NSString *> *skips, *watches;
    NSArray<NSDictionary *> *pokes;
    { std::lock_guard<std::recursive_mutex> lock(guard()); skips = labSkips; watches = labWatches; pokes = labPokes; }
    unsigned rules = 0;
    for (NSString *text in skips) if (name && [name rangeOfString:text].location != NSNotFound) { rules |= 1; break; }
    for (NSString *text in watches) if (name && [name rangeOfString:text].location != NSNotFound) { rules |= 2; break; }
    for (NSDictionary *rule in pokes) if (name && [name rangeOfString:rule[@"text"]].location != NSNotFound) { rules |= 4; break; }
    objc_setAssociatedObject(state,&labRulesKey,@(generation << 3 | rules),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return rules;
}
// The bytes a constant binding currently supplies, when the CPU can read them.
static NSData *labBindingBytes(__unsafe_unretained BG3MFXEncoderState *s, EncoderStage stage, NSUInteger index, NSUInteger limit) {
    ConstantBinding &b = s->constants[stage][index];
    if (b.hasBytes) return s->bytes[@(stage*EncoderSlots+index)];
    if (!b.buffer || b.buffer.storageMode == MTLStorageModePrivate || b.offset >= b.buffer.length || !b.buffer.contents) return nil;
    return [NSData dataWithBytes:(const uint8_t *)b.buffer.contents+b.offset length:MIN(limit,b.buffer.length-b.offset)];
}
struct LabPoke { EncoderStage stage; NSUInteger index; ConstantBinding original; __strong NSData *originalBytes; };
static void labBindBytes(id encoder, EncoderStage stage, NSData *data, NSUInteger index) {
    if (stage == StageVertex) [(id<MTLRenderCommandEncoder>)encoder setVertexBytes:data.bytes length:data.length atIndex:index];
    else if (stage == StageFragment) [(id<MTLRenderCommandEncoder>)encoder setFragmentBytes:data.bytes length:data.length atIndex:index];
    else [(id<MTLComputeCommandEncoder>)encoder setBytes:data.bytes length:data.length atIndex:index];
}
// Applies matching poke rules to a draw or dispatch; labUnpoke restores the bindings.
static std::vector<LabPoke> labPoke(__unsafe_unretained id encoder) {
    std::vector<LabPoke> applied;
    __unsafe_unretained BG3MFXEncoderState *s = encoderState(encoder);
    if (!s || !s->labPoke || !s->labPipeline) return applied;
    NSArray<NSDictionary *> *pokes;
    { std::lock_guard<std::recursive_mutex> lock(guard()); pokes = labPokes; }
    bool render = [encoder respondsToSelector:@selector(setFragmentBytes:length:atIndex:)];
    NSMutableDictionary<NSNumber *, NSMutableData *> *patched = [NSMutableDictionary dictionary];
    for (NSDictionary *rule in pokes) {
        if ([s->labPipeline rangeOfString:rule[@"text"]].location == NSNotFound) continue;
        EncoderStage stage = (EncoderStage)[rule[@"stage"] intValue];
        if (render == (stage == StageCompute)) continue;
        NSUInteger index = [rule[@"index"] unsignedIntegerValue], offset = [rule[@"offset"] unsignedIntegerValue];
        NSNumber *key = @(stage*EncoderSlots+index);
        NSMutableData *data = patched[key];
        if (!data) {
            NSData *source = labBindingBytes(s,stage,index,4096);
            if (!source) continue;
            data = [source mutableCopy]; patched[key] = data;
            ConstantBinding original = s->constants[stage][index];
            applied.push_back({stage,index,original,original.hasBytes ? source : nil});
        }
        if (offset + 4 > data.length) continue;
        if ([rule[@"integer"] boolValue]) { int value = [rule[@"value"] intValue]; memcpy((uint8_t *)data.mutableBytes+offset,&value,4); }
        else { float value = [rule[@"value"] floatValue]; memcpy((uint8_t *)data.mutableBytes+offset,&value,4); }
    }
    for (NSNumber *key in patched)
        labBindBytes(encoder,(EncoderStage)(key.unsignedIntegerValue/EncoderSlots),patched[key],key.unsignedIntegerValue%EncoderSlots);
    return applied;
}
static void labUnpoke(id encoder, const std::vector<LabPoke> &applied) {
    for (const LabPoke &p : applied) {
        if (p.originalBytes) labBindBytes(encoder,p.stage,p.originalBytes,p.index);
        else if (p.stage == StageVertex) [(id<MTLRenderCommandEncoder>)encoder setVertexBuffer:p.original.buffer offset:p.original.offset atIndex:p.index];
        else if (p.stage == StageFragment) [(id<MTLRenderCommandEncoder>)encoder setFragmentBuffer:p.original.buffer offset:p.original.offset atIndex:p.index];
        else [(id<MTLComputeCommandEncoder>)encoder setBuffer:p.original.buffer offset:p.original.offset atIndex:p.index];
    }
}
// Pokes one draw for the lifetime of the scope.
struct LabPokeScope {
    __unsafe_unretained id encoder; std::vector<LabPoke> applied;
    explicit LabPokeScope(__unsafe_unretained id e) : encoder(e) { if (labEnabled) applied = labPoke(e); }
    ~LabPokeScope() { if (!applied.empty()) labUnpoke(encoder,applied); }
};
static NSDictionary *labTexture(id<MTLTexture> t) {
    if (!t) return nil;
    return @{@"label":t.label ?: @"",@"width":@(t.width),@"height":@(t.height),@"format":@(t.pixelFormat),
             @"id":[NSString stringWithFormat:@"%p",(__bridge void *)t]};
}
static void labBeginEncoder(id encoder, NSString *kind, MTLRenderPassDescriptor *desc, id<MTLCommandBuffer> buffer) {
    if (labSerialize) {
        id<MTLFence> fence = labFence(buffer.device);
        if ([kind isEqualToString:@"render"]) [(id<MTLRenderCommandEncoder>)encoder waitForFence:fence beforeStages:MTLRenderStageVertex];
        else [(id<MTLComputeCommandEncoder>)encoder waitForFence:fence];
    }
    __unsafe_unretained BG3MFXEncoderState *s = encoderState(encoder);
    if (!s) return;
    std::lock_guard<std::recursive_mutex> lock(guard());
    if (labCensus != LabRecording) { s->labRecord = nil; return; }
    NSMutableDictionary *entry = [@{@"kind":kind,@"index":@(labFrame.count),
        @"commandBuffer":[NSString stringWithFormat:@"%p",(__bridge void *)buffer],
        @"draws":[NSMutableDictionary dictionary],@"dispatches":[NSMutableDictionary dictionary]} mutableCopy];
    if (desc) {
        NSMutableArray *colors = [NSMutableArray array];
        for (NSUInteger i = 0; i < 8; ++i) if (NSDictionary *t = labTexture(desc.colorAttachments[i].texture)) [colors addObject:t];
        entry[@"colors"] = colors;
        if (NSDictionary *depth = labTexture(desc.depthAttachment.texture)) entry[@"depth"] = depth;
    }
    [labFrame addObject:entry];
    s->labRecord = entry;
}
static NSArray *labRect(double x, double y, double width, double height) { return @[@(x),@(y),@(width),@(height)]; }
// One watched call: everything bound to it that describes where and what it renders.
static NSDictionary *labWatched(__unsafe_unretained BG3MFXEncoderState *s, NSString *name, NSString *grid) {
    NSMutableDictionary *textures = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < EncoderSlots; ++i) if (id<MTLTexture> t = s->textures[i])
        textures[@(i).stringValue] = @{@"id":[NSString stringWithFormat:@"%p",(__bridge void *)t],@"label":t.label ?: @"",
            @"width":@(t.width),@"height":@(t.height),@"depth":@(t.depth),@"type":@(t.textureType),@"format":@(t.pixelFormat),
            @"hazard":@(t.hazardTrackingMode),@"heap":@(t.heap != nil)};
    NSMutableDictionary *buffers = [NSMutableDictionary dictionary];
    static NSString *const stageNames[] = {@"vertex",@"fragment",@"compute"};
    for (int stage = 0; stage < 3; ++stage) for (NSUInteger i = 0; i < EncoderSlots; ++i) {
        ConstantBinding &b = s->constants[stage][i];
        if (!b.buffer && !b.hasBytes) continue;
        NSData *data = labBindingBytes(s,(EncoderStage)stage,i,1024);
        NSMutableDictionary *info = [@{@"offset":@(b.offset),@"base64":[data base64EncodedStringWithOptions:0] ?: @""} mutableCopy];
        if (b.buffer) [info addEntriesFromDictionary:@{@"id":[NSString stringWithFormat:@"%p",(__bridge void *)b.buffer],
            @"length":@(b.buffer.length),@"storage":@(b.buffer.storageMode),@"hazard":@(b.buffer.hazardTrackingMode),@"heap":@(b.buffer.heap != nil)}];
        buffers[[NSString stringWithFormat:@"%@:%lu",stageNames[stage],(unsigned long)i]] = info;
    }
    NSMutableDictionary *call = [@{@"shader":name,@"textures":textures,@"buffers":buffers} mutableCopy];
    if (grid) call[@"grid"] = grid;
    if (s->hasViewport) call[@"viewport"] = labRect(s->viewport.originX,s->viewport.originY,s->viewport.width,s->viewport.height);
    if (s->hasScissor) call[@"scissor"] = labRect(s->scissor.x,s->scissor.y,s->scissor.width,s->scissor.height);
    return call;
}
static void labCount(__unsafe_unretained BG3MFXEncoderState *s, NSString *table, NSString *grid) {
    NSString *name = s->labPipeline ?: @"(unnamed)";
    NSDictionary *watched = s->labWatch ? labWatched(s,name,grid) : nil;
    if (s->labSkip) name = [name stringByAppendingString:@" [skipped]"];
    std::lock_guard<std::recursive_mutex> lock(guard());
    NSMutableDictionary *entry = s->labRecord, *counts = entry[table];
    counts[name] = @([counts[name] unsignedIntegerValue] + 1);
    if (grid && !entry[@"grids"]) entry[@"grids"] = [NSMutableDictionary dictionary];
    if (grid && !entry[@"grids"][name]) entry[@"grids"][name] = grid;
    if (watched) {
        if (!entry[@"watched"]) entry[@"watched"] = [NSMutableArray array];
        if ([entry[@"watched"] count] < 16) [entry[@"watched"] addObject:watched];
    }
}
// True when the draw or dispatch must be dropped. grid describes a dispatch.
static inline bool labWork(__unsafe_unretained id encoder, NSString *table, NSString *grid = nil) {
    if (!labEnabled) return false;
    __unsafe_unretained BG3MFXEncoderState *s = encoderState(encoder);
    if (!s) return false;
    if (s->labRecord) labCount(s,table,grid);
    if (labDumpArmed && s->labPipeline) {
        std::lock_guard<std::recursive_mutex> lock(guard());
        bool armed = false;
        for (NSMutableDictionary *dump in labDumps) {
            if (![dump[@"state"] isEqualToString:@"armed"]) continue;
            armed = true;
            NSUInteger slot = [dump[@"slot"] unsignedIntegerValue];
            EncoderStage stage = (EncoderStage)[dump[@"stage"] intValue];
            if ([s->labPipeline rangeOfString:dump[@"text"]].location == NSNotFound || !s->buffer) continue;
            NSUInteger seen = [dump[@"seen"] unsignedIntegerValue] + 1;
            dump[@"seen"] = @(seen);
            if (seen != [dump[@"occurrence"] unsignedIntegerValue]) continue;
            // Copied when this encoder ends, so later passes cannot change it first.
            dump[@"encoder"] = [NSValue valueWithPointer:(__bridge const void *)encoder];
            dump[@"buffer"] = s->buffer; dump[@"shader"] = s->labPipeline; dump[@"viewport"] = s->hasViewport ?
                labRect(s->viewport.originX,s->viewport.originY,s->viewport.width,s->viewport.height) : @[];
            if (dump[@"length"]) {
                ConstantBinding &b = s->constants[stage][slot];
                NSData *bytes = b.hasBytes ? s->bytes[@(stage*EncoderSlots+slot)] : nil;
                if (b.buffer) { dump[@"source"] = b.buffer; dump[@"offset"] = @(b.offset); } else if (bytes) dump[@"bytes"] = bytes;
            } else if (id<MTLTexture> texture = [dump[@"color"] boolValue] ? s->colorTarget : s->textures[slot]) dump[@"texture"] = texture;
            if (dump[@"source"] || dump[@"bytes"] || dump[@"texture"]) { dump[@"state"] = @"captured"; labDumpCaptured = true; }
            else { dump[@"state"] = @"missing"; labWrite([NSString stringWithFormat:@"dump-%@.json",dump[@"tag"]],@{@"tag":dump[@"tag"],@"missing":@YES}); }
        }
        labDumpArmed = armed;
    }
    return s->labSkip;
}
static NSUInteger labBytesPerPixel(MTLPixelFormat format) {
    switch (format) {
        case MTLPixelFormatR8Unorm: return 1;
        case MTLPixelFormatR16Float: case MTLPixelFormatRG8Unorm: return 2;
        case MTLPixelFormatR32Float: case MTLPixelFormatRG16Float: case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatBGRA8Unorm:
        case MTLPixelFormatRG11B10Float: case MTLPixelFormatRGB10A2Unorm: return 4;
        case MTLPixelFormatRGBA16Float: case MTLPixelFormatRG32Float: return 8;
        case MTLPixelFormatRGBA32Float: return 16;
        default: return 0;
    }
}
// After the encoder that matched a dump ends (or, as a fallback, at commit):
// copy the resource out in the same command buffer.
static void labWriteDumps(id<MTLCommandBuffer> buffer, __unsafe_unretained id encoder = nil) {
    NSMutableArray<NSMutableDictionary *> *mine = [NSMutableArray array];
    { std::lock_guard<std::recursive_mutex> lock(guard());
      for (NSMutableDictionary *dump in labDumps)
          if ([dump[@"state"] isEqualToString:@"captured"] && dump[@"buffer"] == buffer &&
              (!encoder || [dump[@"encoder"] pointerValue] == (__bridge const void *)encoder)) { dump[@"state"] = @"copying"; [mine addObject:dump]; } }
    for (NSMutableDictionary *dump in mine) {
        NSString *bufferTag = dump[@"tag"];
        if (dump[@"length"]) {
            NSUInteger length = [dump[@"length"] unsignedIntegerValue];
            NSDictionary *meta = @{@"tag":bufferTag,@"shader":dump[@"shader"] ?: @"",@"index":dump[@"slot"],@"stage":dump[@"stage"],
                @"occurrence":dump[@"occurrence"],@"viewport":dump[@"viewport"] ?: @[],@"frame":@(frames)};
            if (NSData *bytes = dump[@"bytes"]) {
                [bytes writeToFile:[labDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"dump-%@.raw",bufferTag]] atomically:YES];
                labWrite([NSString stringWithFormat:@"dump-%@.json",bufferTag],meta);
            } else {
                id<MTLBuffer> source = dump[@"source"];
                NSUInteger offset = [dump[@"offset"] unsignedIntegerValue];
                length = MIN(length, source.length > offset ? source.length - offset : 0);
                id<MTLBuffer> copy = length ? [buffer.device newBufferWithLength:length options:MTLResourceStorageModeShared] : nil;
                if (copy) {
                    id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
                    [blit copyFromBuffer:source sourceOffset:offset toBuffer:copy destinationOffset:0 size:length];
                    [blit endEncoding];
                    NSMutableDictionary *full = [meta mutableCopy]; full[@"length"] = @(length); full[@"storage"] = @(source.storageMode);
                    [buffer addCompletedHandler:^(id<MTLCommandBuffer>) {
                        [[NSData dataWithBytes:copy.contents length:copy.length] writeToFile:[labDirectory stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"dump-%@.raw",bufferTag]] atomically:YES];
                        labWrite([NSString stringWithFormat:@"dump-%@.json",bufferTag],full);
                        fprintf(stderr,"BG3 MetalFX lab: dump %s written\n",bufferTag.UTF8String);
                    }];
                }
            }
            std::lock_guard<std::recursive_mutex> lock(guard());
            dump[@"state"] = @"written"; [dump removeObjectsForKeys:@[@"source",@"bytes",@"buffer",@"encoder"]];
            continue;
        }
        id<MTLTexture> texture = dump[@"texture"];
        NSUInteger bpp = labBytesPerPixel(texture.pixelFormat);
        NSUInteger row = texture.width*bpp, image = row*texture.height;
        id<MTLBuffer> copy = bpp ? [buffer.device newBufferWithLength:image*texture.depth options:MTLResourceStorageModeShared] : nil;
        NSString *tag = dump[@"tag"];
        NSDictionary *meta = @{@"tag":tag,@"shader":dump[@"shader"] ?: @"",@"slot":dump[@"slot"],@"label":texture.label ?: @"",
            @"width":@(texture.width),@"height":@(texture.height),@"depth":@(texture.depth),@"format":@(texture.pixelFormat),
            @"bytesPerPixel":@(bpp),@"bytesPerRow":@(row),@"frame":@(frames),@"mipmaps":@(texture.mipmapLevelCount),
            @"type":@(texture.textureType),@"occurrence":dump[@"occurrence"],@"viewport":dump[@"viewport"] ?: @[],@"color":dump[@"color"] ?: @NO};
        if (!copy) { labWrite([NSString stringWithFormat:@"dump-%@.json",tag],meta); continue; }
        id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
        [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(texture.width,texture.height,texture.depth) toBuffer:copy destinationOffset:0
            destinationBytesPerRow:row destinationBytesPerImage:image];
        [blit endEncoding];
        [buffer addCompletedHandler:^(id<MTLCommandBuffer>) {
            [[NSData dataWithBytes:copy.contents length:copy.length] writeToFile:[labDirectory stringByAppendingPathComponent:
                [NSString stringWithFormat:@"dump-%@.raw",tag]] atomically:YES];
            labWrite([NSString stringWithFormat:@"dump-%@.json",tag],meta);
            fprintf(stderr,"BG3 MetalFX lab: dump %s written\n",tag.UTF8String);
        }];
        std::lock_guard<std::recursive_mutex> lock(guard());
        dump[@"state"] = @"written"; [dump removeObjectsForKeys:@[@"texture",@"buffer",@"encoder"]];
    }
}
// About once a second: presented frames, command buffers and GPU busy time.
static void labPerf(void) {
    static double last; static unsigned long lastFrames; static uint64_t lastCommits, lastGPU, lastMetal4;
    double now = CACurrentMediaTime();
    if (now - last < 1.0) return;
    uint64_t commits = labCommits.load(), gpu = labGPUNanoseconds.load(), metal4 = labMetal4Nanoseconds.load();
    if (last) {
        double span = now - last, presented = (double)(frames - lastFrames);
        labMetal4MsPerFrame = presented ? (metal4-lastMetal4)*1e-6/presented : 0;
        labWrite(@"perf.json",@{@"seconds":@(span),@"fps":@(presented/span),@"commandBuffersPerSecond":@((commits-lastCommits)/span),
            @"gpuBusy":@((gpu-lastGPU)*1e-9/span),@"gpuMsPerFrame":@(presented ? (gpu-lastGPU)*1e-6/presented : 0),
            @"metal4MsPerFrame":@(presented ? (metal4-lastMetal4)*1e-6/presented : 0),@"frame":@(frames),
            @"metal4Reordered":@(BG3MFXMetal4Reordered())});
    }
    last = now; lastFrames = frames; lastCommits = commits; lastGPU = gpu; lastMetal4 = metal4;
}
static void labFrameBoundary(void) {
    labPoll();
    labPerf();
    std::lock_guard<std::recursive_mutex> lock(guard());
    if (labDumpArmed) for (NSMutableDictionary *dump in labDumps) if ([dump[@"state"] isEqualToString:@"armed"]) dump[@"seen"] = @0;
    if (labCensus == LabArmed) {
        labFrame = [NSMutableArray array]; labCensus = LabRecording;
        if (labProfileRequested) { labProfiling = true; labSamples = 0; labProfileRequested = false; }
        return;
    }
    if (labCensus != LabRecording) return;
    if (labProfiling) {
        // Resolve once the GPU has certainly finished the frame.
        labProfiling = false;
        NSArray *frame = labFrame; NSUInteger count = labSamples; NSString *name = labCensusName;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.5*NSEC_PER_SEC)),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
            std::lock_guard<std::recursive_mutex> hold(guard());
            labWriteProfile(frame,count,name);
        });
    }
    NSMutableDictionary *layouts = [NSMutableDictionary dictionary];
    for (NSString *name in labLayouts) for (NSString *text in labWatches)
        if ([name rangeOfString:text].location != NSNotFound) layouts[name] = labLayouts[name];
    labWrite([NSString stringWithFormat:@"census-%@.json",labCensusName],
        @{@"census":labCensusName,@"frame":@(frames),@"skip":labSkips ?: @[],@"encoders":labFrame,@"vertexLayouts":layouts});
    fprintf(stderr,"BG3 MetalFX lab: census %s recorded %lu encoders\n",labCensusName.UTF8String,(unsigned long)labFrame.count);
    labFrame = nil; labCensus = LabIdle;
}
#ifndef BG3MFX_NO_TRACE
static char waterfallCopiesKey;
static NSDictionary *waterfallLayout(MTLRenderPipelineDescriptor *desc) {
    if (![desc.vertexFunction.name containsString:@"Water_Fall_Foam_STI_"]) return nil;
    NSMutableArray *attributes=[NSMutableArray array], *layouts=[NSMutableArray array];
    for (NSUInteger i=0;i<31;++i) {
        MTLVertexAttributeDescriptor *a=desc.vertexDescriptor.attributes[i];
        if (a.format!=MTLVertexFormatInvalid) [attributes addObject:@{@"attribute":@(i),@"format":@(a.format),@"offset":@(a.offset),@"buffer":@(a.bufferIndex)}];
        MTLVertexBufferLayoutDescriptor *l=desc.vertexDescriptor.layouts[i];
        if (l.stride) [layouts addObject:@{@"buffer":@(i),@"stride":@(l.stride),@"stepFunction":@(l.stepFunction),@"stepRate":@(l.stepRate)}];
    }
    return @{@"attributes":attributes,@"layouts":layouts};
}
static void captureWaterfall(id encoder, NSDictionary *draw) {
    const char *directory=getenv("BG3MFX_CAPTURE_WATERFALL");
    if (!directory || !*directory) return;
    NSDictionary *pipelineState=pipelineDescription(encoder);
    NSString *vertex=pipelineState[@"vertex"];
    if (![vertex containsString:@"Water_Fall_Foam_STI_DEP_vertexMain"] &&
        ![vertex containsString:@"Water_Fall_Foam_STI_VEL_vertexMain"]) return;
    std::lock_guard<std::recursive_mutex> lock(guard());
    static NSMutableDictionary *counts=[NSMutableDictionary dictionary];
    static NSUInteger totalBytes=0, serial=0;
    NSString *key=[NSString stringWithFormat:@"%d:%@",encoderScalingMode(encoder),vertex];
    NSUInteger count=[counts[key] unsignedIntegerValue];
    if (count>=4) return;
    counts[key]=@(count+1);
    NSString *root=[NSString stringWithUTF8String:directory];
    if (![root isAbsolutePath]) return;
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *stem=[NSString stringWithFormat:@"draw-%lu-mode-%d",(unsigned long)serial++,encoderScalingMode(encoder)];
    NSMutableDictionary *bindings=[constantBindings(encoder) mutableCopy];
    id<MTLBuffer> indexBuffer=draw[@"indexBuffer"];
    if (indexBuffer) bindings[@"index"]=@{@"buffer":indexBuffer,@"offset":draw[@"indexOffset"] ?: @0};
    NSMutableDictionary *snapshots=[NSMutableDictionary dictionary];
    NSMutableArray *copies=objc_getAssociatedObject(encoder,&waterfallCopiesKey);
    if (!copies) { copies=[NSMutableArray array]; objc_setAssociatedObject(encoder,&waterfallCopiesKey,copies,OBJC_ASSOCIATION_RETAIN_NONATOMIC); noteAssociation(encoder,AssocWaterfall); }
    for (NSString *slot in bindings) {
        BOOL index=[slot isEqualToString:@"index"];
        NSUInteger slotIndex=[slot componentsSeparatedByString:@":"].lastObject.integerValue;
        BOOL stream=NO;
        for (NSDictionary *layout in pipelineState[@"vertexLayout"][@"layouts"])
            if ([layout[@"buffer"] unsignedIntegerValue]==slotIndex) stream=YES;
        if (!index && (![slot hasPrefix:@"vertex:"] || (!stream && slotIndex!=20 && slotIndex!=13 && slotIndex!=11 && slotIndex!=8))) continue;
        NSDictionary *binding=bindings[slot]; id<MTLBuffer> buffer=binding[@"buffer"];
        NSUInteger offset=[binding[@"offset"] unsignedIntegerValue];
        NSData *bytes=binding[@"bytes"];
        NSUInteger length=buffer ? (offset<=buffer.length ? buffer.length-offset:0) : bytes.length;
        NSUInteger limit=index || stream ? 8*1024*1024UL : (slotIndex==20 ? 64 : (slotIndex==13 ? 32 : 224));
        NSUInteger captured=MIN(length,limit);
        if (totalBytes+captured>128*1024*1024UL) captured=0;
        totalBytes+=captured;
        NSString *file=[stem stringByAppendingFormat:@"-%@.bin",[slot stringByReplacingOccurrencesOfString:@":" withString:@"-"]];
        snapshots[slot]=@{@"file":file,@"offset":@(offset),@"availableLength":@(length),@"capturedLength":@(captured),@"storage":buffer ? @(buffer.storageMode):@(-1)};
        if (!captured) continue;
        if (bytes) [[bytes subdataWithRange:NSMakeRange(0,captured)] writeToFile:[root stringByAppendingPathComponent:file] atomically:YES];
        else if (buffer.storageMode==MTLStorageModeShared && buffer.contents)
            [[NSData dataWithBytes:(const uint8_t *)buffer.contents+offset length:captured] writeToFile:[root stringByAppendingPathComponent:file] atomically:YES];
        else if (buffer.storageMode==MTLStorageModePrivate)
            [copies addObject:@{@"buffer":buffer,@"offset":@(offset),@"length":@(captured),@"path":[root stringByAppendingPathComponent:file]}];
    }
    NSMutableDictionary *drawInfo=[draw mutableCopy]; [drawInfo removeObjectForKey:@"indexBuffer"];
    NSDictionary *info=@{@"pipeline":pipelineState,@"mode":@(encoderScalingMode(encoder)),@"draw":drawInfo,@"bindings":snapshots,
        @"limitation":@"Bounded buffer capture; noise texture is not captured. Private buffers copied after this encoder."};
    [[NSJSONSerialization dataWithJSONObject:info options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[root stringByAppendingPathComponent:[stem stringByAppendingString:@".json"]] atomically:YES];
    record(@{@"event":@"waterfallDrawCaptured",@"path":[root stringByAppendingPathComponent:[stem stringByAppendingString:@".json"]],@"mode":@(encoderScalingMode(encoder))});
}
static void finishWaterfallCopies(id<MTLCommandBuffer> commandBuffer, NSArray *copies) {
    if (!commandBuffer || !copies.count) return;
    id<MTLBlitCommandEncoder> blit=[commandBuffer blitCommandEncoder];
    NSMutableArray *results=[NSMutableArray array];
    for (NSDictionary *copy in copies) {
        NSUInteger length=[copy[@"length"] unsignedIntegerValue];
        id<MTLBuffer> readback=[commandBuffer.device newBufferWithLength:length options:MTLResourceStorageModeShared];
        if (!readback) continue;
        [blit copyFromBuffer:copy[@"buffer"] sourceOffset:[copy[@"offset"] unsignedIntegerValue] toBuffer:readback destinationOffset:0 size:length];
        [results addObject:@{@"buffer":readback,@"path":copy[@"path"]}];
    }
    [blit endEncoding];
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        if (completed.status!=MTLCommandBufferStatusCompleted) return;
        for (NSDictionary *result in results) {
            id<MTLBuffer> readback=result[@"buffer"];
            [[NSData dataWithBytes:readback.contents length:readback.length] writeToFile:result[@"path"] atomically:YES];
        }
    }];
}
#endif
// Every hook calls this; a locked map search per call was measurable on BG3's
// render thread. Cache per thread; any change to originals() bumps the generation.
static IMP originalSlow(Class concrete, SEL selector, unsigned generation, OriginalCacheEntry &entry) {
    std::lock_guard<std::recursive_mutex> lock(guard());
    for (Class cls = concrete; cls; cls = class_getSuperclass(cls)) {
        auto it = originals().find({cls, selector});
        if (it != originals().end()) { entry = {concrete, selector, it->second, generation}; return it->second; }
    }
    // Another library exchanged a hooked method with one of its own (the Steam
    // overlay does this for -commit and, with VSync, the timed present), so a
    // replacement runs under that library's selector. Find the hooked method
    // by the replacement it carries. One replacement can serve several
    // selectors (presentTimed takes both timed presents): the exchanged one is
    // the one no longer running it under its own name.
    if (Method method = class_getInstanceMethod(concrete, selector)) {
        IMP running = method_getImplementation(method), any = nullptr, exchanged = nullptr;
        bool anyAmbiguous = false, exchangedAmbiguous = false;
        for (Class cls = concrete; cls; cls = class_getSuperclass(cls))
            for (auto &[key, replacement] : replacements()) {
                if (key.first != cls || replacement != running) continue;
                IMP imp = originals()[key];
                if (any && imp != any) anyAmbiguous = true;
                any = imp;
                Method hooked = class_getInstanceMethod(cls, key.second);
                if (hooked && method_getImplementation(hooked) == replacement) continue;
                if (exchanged && imp != exchanged) exchangedAmbiguous = true;
                exchanged = imp;
            }
        IMP found = exchanged && !exchangedAmbiguous ? exchanged : any && !anyAmbiguous ? any : nullptr;
        if (found) { entry = {concrete, selector, found, generation}; return found; }
    }
    abort();
}
static void hook(id object, const char *name, IMP replacement) {
    if (!object) return;
    std::lock_guard<std::recursive_mutex> lock(guard());
    Class cls = object_getClass(object);
    SEL selector = sel_registerName(name);
    if (originals().count({cls, selector})) return;
    // If a superclass is already hooked, leave inherited dispatch alone.
    // Some driver methods are resolved lazily. Ask the instance first so the
    // runtime has a chance to install a supported selector before inspection.
    if (![object respondsToSelector:selector]) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getImplementation(method) == replacement) return;
    originals()[{cls, selector}] = method_getImplementation(method);
    replacements()[{cls, selector}] = replacement;
    originalsGeneration.fetch_add(1, std::memory_order_release);
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
}
static void markPrepassPipeline(id pipeline, TrimPipeline value) {
    if (__unsafe_unretained BG3MFXPipelineInfo *info = objc_getAssociatedObject(pipeline, &pipelineKey)) info->trim = value;
}
static void setPrepassDepth(__unsafe_unretained id encoder, __unsafe_unretained id state) {
    SEL set = @selector(setDepthStencilState:);
    ((void(*)(id,SEL,id))original(encoder,set))(encoder,set,state);
}
static BG3MFXPrepassState *prepassState(__unsafe_unretained id encoder) {
    if (!prepassTrim) return nullptr;
    __unsafe_unretained BG3MFXEncoderState *s = encoderState(encoder);
    return s ? &s->prepass : nullptr;
}
// For each Equal/no-write state (a G-buffer draw tested against the prepass),
// an otherwise identical state that tests GreaterEqual and writes depth.
static id depthStencilStateHook(id self, SEL cmd, MTLDepthStencilDescriptor *desc) {
    id state = ((id(*)(id,SEL,id))original(self,cmd))(self,cmd,desc);
    if (prepassTrim) BG3MFXPreparePrepassDepth(self,cmd,desc,state,(BG3MFXCreateDepthState)original(self,cmd));
    return state;
}
static void setDepthStencilHook(__unsafe_unretained id self, SEL cmd, __unsafe_unretained id state) {
    ((void(*)(id,SEL,id))original(self,cmd))(self,cmd,state);
    if (__unsafe_unretained BG3MFXEncoderState *s = encoderState(self)) {
#ifndef BG3MFX_NO_TRACE
        if (redundantProbe) {
            ++redundantCounts[DepthBinds];
            if (s->seenDepth==state) ++redundantCounts[DepthBindsRedundant];
            s->seenDepth=state;
        }
#endif
        s->prepass.depthState = state;
    }
}
static NSDictionary *texture(id<MTLTexture> t) {
    if (!t) return @{};
    std::lock_guard<std::recursive_mutex> lock(guard());
    NSNumber *identifier = objc_getAssociatedObject(t, &resourceKey);
    if (!identifier) {
        identifier = @(++resourceCounter);
        objc_setAssociatedObject(t, &resourceKey, identifier, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return @{@"id": identifier, @"label": t.label ?: @"", @"width": @(t.width), @"height": @(t.height),
             @"format": @(t.pixelFormat), @"usage": @(t.usage), @"storage": @(t.storageMode),
             @"hazardTracking": @(t.hazardTrackingMode), @"textureType": @(t.textureType),
             @"arrayLength": @(t.arrayLength), @"sampleCount": @(t.sampleCount)};
}
static void label(id self, SEL cmd, NSString *value) {
    ((void(*)(id,SEL,id))original(self,cmd))(self,cmd,value);
    if (value.length) record(@{@"event": @"label", @"class": NSStringFromClass(object_getClass(self)), @"value": value});
}
static void group(id self, SEL cmd, NSString *value) {
    ((void(*)(id,SEL,id))original(self,cmd))(self,cmd,value);
    if (value.length) record(@{@"event": @"group", @"value": value});
}
static void rememberTexture(__unsafe_unretained id self, SEL cmd, __unsafe_unretained id<MTLTexture> t, NSUInteger index) {
    (void)cmd; // Only diagnostic builds include the selector in event records.
    if (!diagnostics) {
        // Metal permits textures to be bound before pipeline state. Retain the
        // three required slots independently of shader identification. The
        // index test comes first: BG3 binds about 30,000 slots per frame. Lab
        // mode keeps every slot for its watch records.
        if (!labEnabled) {
            if (index > 2) return;
            if (!metalFXEnabled && encoderScalingMode(self) != 2) return;
        }
    }
    if ((sceneProbe || metalFXEnabled || labEnabled) && index < EncoderSlots)
        if (__unsafe_unretained BG3MFXEncoderState *s=encoderState(self)) s->textures[index]=t;
    if (diagnostics) {
        std::lock_guard<std::recursive_mutex> lock(guard());
        NSString *slot = [NSString stringWithFormat:@"%lu", (unsigned long)index];
        NSMutableDictionary *bindings = objc_getAssociatedObject(self, &bindingsKey);
        if (!bindings) {
            bindings = [NSMutableDictionary dictionary];
            objc_setAssociatedObject(self, &bindingsKey, bindings, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            noteAssociation(self,AssocBindings);
        }
        if (t) bindings[slot] = texture(t); else [bindings removeObjectForKey:slot];
        if (t) record(@{@"event": NSStringFromSelector(cmd), @"encoder": [self label] ?: @"", @"pipeline": pipelineDescription(self) ?: @{}, @"index": @(index), @"texture": texture(t)});
    }
}
static void bindTexture(__unsafe_unretained id self, SEL cmd, __unsafe_unretained id<MTLTexture> t, NSUInteger index) {
    if (diagnostics && redundantProbe) { id<MTLTexture> const one[1]={t}; countTextures(self,cmd,one,NSMakeRange(index,1)); }
    if (bindDedup && cmd==@selector(setFragmentTexture:atIndex:))
        if (__unsafe_unretained BG3MFXEncoderState *s=encoderState(self))
            if (!s->bindFilter.forwardTexture(t,index)) { rememberTexture(self,cmd,t,index); return; }
    ((void(*)(id,SEL,id,NSUInteger))original(self,cmd))(self,cmd,t,index);
    rememberTexture(self,cmd,t,index);
}
static void bindTextures(__unsafe_unretained id self, SEL cmd, id<MTLTexture> const *textures, NSRange range) {
    countTextures(self,cmd,textures,range);
    __unsafe_unretained BG3MFXEncoderState *s=bindDedup && cmd==@selector(setFragmentTextures:withRange:) ? encoderState(self) : nil;
    auto forward=((void(*)(id,SEL,id<MTLTexture> const *,NSRange))original(self,cmd));
    if (s) s->bindFilter.forwardTextures(textures,range,[&](id<MTLTexture> const *run, NSRange slots) {
        forward(self,cmd,run,slots);
    });
    else forward(self,cmd,textures,range);
    for (NSUInteger i=0; i<range.length; ++i) rememberTexture(self,cmd,textures[i],range.location+i);
}
static void probeScene(id<MTLCommandBuffer> buffer, NSDictionary *inputs);
// Failures never close the game: the player may have unsaved progress. Each
// turns off the part that failed and tells the player once, on the main run
// loop (never from a hook or from dyld's constructor).
static void showNotice(NSString *title, NSString *text) {
    // Noninteractive regressions read the message from stderr instead.
    if (getenv("BG3MFX_TEST_ERRORS_STDERR") && strcmp(getenv("BG3MFX_TEST_ERRORS_STDERR"),"1") == 0) return;
    dispatch_async(dispatch_get_main_queue(),^{
        [NSApplication sharedApplication];
        NSAlert *alert=[NSAlert new]; alert.messageText=title; alert.informativeText=text;
        [alert addButtonWithTitle:@"OK"]; [alert runModal];
    });
}
// A frame whose inputs or composition Frame Generation cannot reproduce turns it
// off without closing the game: the selected upscaler keeps running, and frames
// already rendered into stand-ins are presented unpaired. Clearing the Frame
// Generation checkbox and checking it again retries.
static std::atomic<bool> frameGenerationDeclined{false};
static void declineFrameGeneration(NSString *reason) {
    if(frameGenerationDeclined.exchange(true)) return;
    record(@{@"event":@"frameGenerationDeclined",@"reason":reason ?: @""});
    fprintf(stderr,"MetalFX Frame Generation is off: %s\n",(reason ?: @"").UTF8String); fflush(stderr);
    showNotice(@"MetalFX Frame Generation is off",[(reason ?: @"") stringByAppendingString:
        @"\n\nThe game continues with the selected Upscaling Type and without Frame Generation. "
        "To retry, turn Frame Generation off and on again in Video options."]);
}
// frameInterpolator, frameConfiguration and previousFrameTime belong to BG3's
// render thread. framePresenter is also read by layerNextDrawable, so it is
// written under the guard.
static BG3MFXFrameInterpolation *frameInterpolator;
static BG3MFXFramePresenter *framePresenter;
static NSString *frameConfiguration;
static double previousFrameTime;
// Menu callbacks run on another thread; the render thread applies their reset
// at its next generated frame instead of touching its objects concurrently.
static std::atomic<bool> frameGenerationResetPending{false};
// Unchecking Frame Generation frees the interpolator and
// presentation worker instead of leaving an idle effect alive. The worker joins
// its thread after draining queued pairs, so release it off the render thread.
static void releaseFrameGeneration(void) {
    BG3MFXFramePresenter *presenter;
    { std::lock_guard<std::recursive_mutex> lock(guard()); presenter=framePresenter; framePresenter=nil; }
    frameInterpolator=nil; frameConfiguration=nil; previousFrameTime=0;
    if (presenter) dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{ (void)presenter; });
    record(@{@"event":@"frameGenerationReleased"});
}
static void resetFrameGeneration(void) { frameGenerationResetPending=true; }
static void encodeGeneratedPair(id<MTLCommandBuffer> buffer, NSDictionary *request);

// A failed MetalFX upscaler is off until the player chooses an Upscaling Type
// again: BG3's TAA and FSR, which the menu has already set up underneath,
// render instead (see dispatch and suppressTemporalTAA).
static void failFeature(BOOL temporal, NSString *reason) {
    { std::lock_guard<std::recursive_mutex> lock(guard());
      if (temporal ? temporalFailed : spatialFailed) return;
      if (temporal) temporalFailed = YES; else spatialFailed = YES; }
    if (temporal) temporalResetPending = true;
    NSString *feature = temporal ? @"Temporal" : @"Spatial";
    if (![reason isKindOfClass:NSString.class] || reason.length == 0)
        reason = @"MetalFX could not initialize or validate the requested frame.";
    NSString *message = [[@"MetalFX " stringByAppendingString:feature] stringByAppendingFormat:@" stopped: %@",reason];
    fprintf(stderr,"%s\n",message.UTF8String); fflush(stderr);
    record(@{@"event":temporal ? @"temporalUpscaleError" : @"spatialUpscaleError",@"error":message});
    showNotice([NSString stringWithFormat:@"MetalFX %@ is off",feature],[reason stringByAppendingString:
        @"\n\nThe game continues with AMD FSR 1.0 upscaling. To retry, choose another Upscaling Type "
        "and then this one again in Video options."]);
}
static void failSpatial(NSString *reason) { failFeature(NO,reason); }
static void failTemporal(NSString *reason) { failFeature(YES,reason); }
// Menu integration problems leave BG3's own options working; say so once.
static void noticeMenuProblem(NSString *reason) {
    static std::atomic<bool> shown{false};
    if (![reason isKindOfClass:NSString.class] || reason.length == 0) reason = @"The Video options could not be extended.";
    fprintf(stderr,"MetalFX menu integration: %s\n",reason.UTF8String); fflush(stderr);
    if (shown.exchange(true)) return;
    showNotice(@"MetalFX options may be unavailable",[reason stringByAppendingString:
        @"\n\nThe game continues with its own video options."]);
}
static void menuReport(NSDictionary *event) {
    record(event);
    if (labEnabled) BG3MFXLabInputNote(event);
    if ([event[@"event"] isEqualToString:@"nativeMenuError"])
        noticeMenuProblem(event[@"error"]);
    // Choosing a different Upscaling Type retries a failed MetalFX upscaler.
    if ([event[@"event"] isEqualToString:@"upscalingModeChanged"] && [event[@"changed"] boolValue]) {
        std::lock_guard<std::recursive_mutex> lock(guard());
        spatialFailed = temporalFailed = NO;
    }
    if ([event[@"event"] isEqualToString:@"frameGenerationChanged"] || [event[@"event"] isEqualToString:@"upscalingModeChanged"]) {
        resetFrameGeneration();
        // Changing either way starts the next enabled run with fresh history.
        extern void BG3MFXResetTemporalHistory(void);
        BG3MFXResetTemporalHistory();
    }
}
static NSString *scalerKey(id<MTLDevice> device, NSUInteger iw, NSUInteger ih, NSUInteger ow, NSUInteger oh) {
    return [NSString stringWithFormat:@"%p:%lu:%lu:%lu:%lu",(__bridge void *)device,iw,ih,ow,oh];
}
// Creating a scaler takes tens of milliseconds. Dragging a window edge gives
// every frame a new size, so a size with no scaler runs BG3's native FSR until
// it has held for a moment; the first scaler of the session is created at once.
struct PendingSize { NSString *key; double since; };
static BOOL sizeSettled(NSString *key, NSDictionary *cache, PendingSize &pending) {
    std::lock_guard<std::recursive_mutex> lock(guard());
    if (cache[key] || !cache.count) return YES;
    double now=NSProcessInfo.processInfo.systemUptime;
    if (![key isEqualToString:pending.key]) { pending.key=key; pending.since=now; return NO; }
    return now-pending.since>=0.3;
}
// Spatial scalers are freed normally. Keep only the sizes in use, the current
// one and the one before it (two views of different sizes may alternate):
// keeping every size held each one's scaler and pooled textures for the rest
// of the session, about 7 MB per size even at 384×384 → 768×768.
static constexpr NSUInteger SpatialCachedSizes = 2;
static NSMutableDictionary<NSString *, BG3MFXSpatialUpscaler *> *spatialUpscalerCache() {
    static NSMutableDictionary *value = [NSMutableDictionary dictionary];
    return value;
}
static NSMutableArray<NSString *> *spatialUpscalerOrder() {  // least recently used first
    static NSMutableArray *value = [NSMutableArray array];
    return value;
}
// A split-screen frame's views have a scaler each, cached by view size: the
// frame's size (each cached scaler's group) is settled once one was made for it.
static NSMutableDictionary<NSString *, NSString *> *spatialUpscalerGroups() {
    static NSMutableDictionary *value = [NSMutableDictionary dictionary];
    return value;
}
static BOOL spatialSizeSettled(NSString *key) {
    static PendingSize pending;
    {
        std::lock_guard<std::recursive_mutex> lock(guard());
        if ([spatialUpscalerGroups().allValues containsObject:key]) return YES;
    }
    return sizeSettled(key,spatialUpscalerCache(),pending);
}
static BOOL upscaleSpatial(id<MTLCommandBuffer> buffer, NSDictionary *inputs) {
    id<MTLTexture> input = inputs[@"input"], destination = inputs[@"destination"];
    if (!input || !destination) return NO;
    // Fetch/store under the tracer guard, but construct MetalFX outside it:
    // synchronous driver initialization can call our hooks on other threads.
    NSString *key = scalerKey(buffer.device,input.width,input.height,destination.width,destination.height);
    id<MTLTexture> frameInput = inputs[@"encodedInput"], frameOutput = inputs[@"scaled"];
    NSString *group = inputs[@"view"] && frameInput && frameOutput
        ? scalerKey(buffer.device,frameInput.width,frameInput.height,frameOutput.width,frameOutput.height) : key;
    BG3MFXSpatialUpscaler *upscaler;
    { std::lock_guard<std::recursive_mutex> lock(guard()); upscaler = spatialUpscalerCache()[key]; }
    NSError *error = nil;
    if (!upscaler) upscaler = [[BG3MFXSpatialUpscaler alloc] initWithDevice:buffer.device inputWidth:input.width
        inputHeight:input.height outputWidth:destination.width outputHeight:destination.height error:&error];
    if (upscaler) {
        // Frames in flight keep an evicted scaler alive until they complete.
        std::lock_guard<std::recursive_mutex> lock(guard());
        NSMutableArray<NSString *> *order = spatialUpscalerOrder();
        [order removeObject:key]; [order addObject:key];
        spatialUpscalerCache()[key] = upscaler; spatialUpscalerGroups()[key] = group;
        while (order.count > SpatialCachedSizes) {
            [spatialUpscalerCache() removeObjectForKey:order.firstObject];
            [spatialUpscalerGroups() removeObjectForKey:order.firstObject]; [order removeObjectAtIndex:0];
        }
    }
    BOOL encoded = upscaler && [upscaler encodeHDRColor:input destination:destination commandBuffer:buffer error:&error];
    record(@{@"event": @"spatialUpscaleEncoded", @"success": @(encoded),
        @"input": texture(input), @"destination": texture(destination), @"error": error.description ?: @""});
    if (encoded) [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        record(@{@"event": @"spatialUpscaleCompleted", @"status": @(completed.status),
            @"error": completed.error.description ?: @""});
        if (completed.status != MTLCommandBufferStatusCompleted)
            failSpatial(completed.error.localizedDescription ?: @"Metal could not complete the scaling commands.");
    }];
    if (!encoded) failSpatial(error.localizedDescription ?: @"MetalFX could not encode the spatial frame.");
    return encoded;
}
#if !defined(BG3MFX_NO_TRACE) || defined(BG3MFX_STANDALONE_TEST_HOOKS)
static std::atomic<unsigned> temporalScalersCreated{0};
#endif
static NSMutableDictionary *temporalUpscalerCache() {
    // Initialized once, thread-safely; temporalSizeSettled reads it before
    // taking the guard.
    static NSMutableDictionary *value = [NSMutableDictionary dictionary];
    return value;
}
// The group each cached Temporal scaler belongs to (see upscaleTemporal).
static NSMutableDictionary<NSString *, NSString *> *temporalUpscalerGroups() {
    static NSMutableDictionary *value = [NSMutableDictionary dictionary];
    return value;
}
// On macOS 27.0.1 a Temporal scaler whose output is 1512 px tall or less is
// never deallocated (Metal 3 and Metal 4 alike): each keeps an
// ANEServicesThread and tens to hundreds of MB. Creating one per frame while a
// window edge was dragged stuttered, corrupted the image and eventually hung
// BG3 inside scaler creation with about a thousand leaked threads, so new
// sizes wait to settle and such scalers stay cached for reuse. Taller ones are
// freed, so they are evicted once another size is rendered.
static constexpr NSUInteger TemporalLeakedOutputHeight = 1512;
// Split-screen views' scalers are cached per view (size@view): a size with
// a view's scaler has settled too.
static BOOL temporalSizeSettled(NSString *key) {
    static PendingSize pending;
    {
        std::lock_guard<std::recursive_mutex> lock(guard());
        NSString *prefix = [key stringByAppendingString:@"@"];
        for (NSString *cached in temporalUpscalerCache()) if ([cached hasPrefix:prefix]) return YES;
    }
    return sizeSettled(key,temporalUpscalerCache(),pending);
}
void BG3MFXResetTemporalHistory(void) {
    NSArray<BG3MFXTemporalUpscaler *> *upscalers;
    { std::lock_guard<std::recursive_mutex> lock(guard()); upscalers = temporalUpscalerCache().allValues; }
    for (BG3MFXTemporalUpscaler *upscaler in upscalers) [upscaler resetHistory];
}
static BOOL temporalParameters(NSDictionary *inputs, BG3MFXFrameParameters *parameters, NSString **reason) {
    NSData *cameraData = inputs[@"camera"], *temporalData = inputs[@"temporal"];
    if (cameraData.length < 224 || temporalData.length < 224) {
        if (reason) *reason = @"BG3 did not provide the full camera and temporal constants.";
        return NO;
    }
    const float *camera = (const float *)cameraData.bytes;
    const float *temporal = (const float *)temporalData.bytes;
    BG3MFXFrameParameters p = {};
    // BG3's constants describe the sample displacement, not MetalFX's
    // image/projection displacement. Depth registration and the analytic
    // reconstruction regression establish the opposite sign in both axes.
    BG3MFXApplyTemporalJitter(&p, temporal[52], temporal[53]);
    // Inspected BG3 camera/object shaders emit current minus previous in
    // framebuffer pixels. MetalFX needs previous minus current displacement.
    p.motionScaleX = p.motionScaleY = -1;
    p.depthReversed = YES; p.reset = [inputs[@"reset"] boolValue];
    float nearPlane = camera[48], farPlane = camera[49];
    float fieldOfView = 2 * std::atan(1/camera[21]) * 180 / M_PI;
    float nearDepth = camera[26] + camera[30]/nearPlane;
    float farDepth = camera[26] + camera[30]/farPlane;
    if (!std::isfinite(nearDepth) || !std::isfinite(farDepth) || std::abs(nearDepth-1) > 0.001 ||
        std::abs(farDepth) > 0.001 || nearPlane <= 0 || farPlane <= nearPlane ||
        !std::isfinite(fieldOfView) || fieldOfView <= 0 || fieldOfView >= 180 ||
        !std::isfinite(p.jitterX) || !std::isfinite(p.jitterY) || std::abs(p.jitterX) > 0.5 || std::abs(p.jitterY) > 0.5) {
        if (reason) *reason = @"BG3 supplied an unsupported camera projection or temporal jitter.";
        return NO;
    }
    *parameters = p;
    return YES;
}
#ifndef BG3MFX_NO_TRACE
static void validateMotionSample(id<MTLCommandBuffer> buffer, id<MTLTexture> motion) {
    static std::atomic<unsigned> attempts{0};
    if (!getenv("BG3MFX_VALIDATE_MOTION") || attempts.fetch_add(1) >= 8) return;
    NSUInteger row = (motion.width*4+255)&~NSUInteger(255);
    id<MTLBuffer> data = [buffer.device newBufferWithLength:row*motion.height options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> encoder = [buffer blitCommandEncoder];
    [encoder copyFromTexture:motion sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(motion.width,motion.height,1) toBuffer:data destinationOffset:0
        destinationBytesPerRow:row destinationBytesPerImage:row*motion.height];
    [encoder endEncoding];
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        if (completed.status != MTLCommandBufferStatusCompleted) return;
        NSUInteger nonfinite=0; float maximum=0;
        for (NSUInteger y=0;y<motion.height;++y) for (NSUInteger x=0;x<motion.width;++x) {
            const __fp16 *p=(const __fp16 *)((const uint8_t *)data.contents+y*row+x*4);
            for (int c=0;c<2;++c) { float v=p[c]; if (!std::isfinite(v)) ++nonfinite; else maximum=std::fmax(maximum,std::abs(v)); }
        }
        record(@{@"event":@"temporalMotionValidation",@"nonfinite":@(nonfinite),@"maximumAbsolute":@(maximum),@"motion":texture(motion)});
    }];
}
#endif
// view names a split-screen view: it gets a scaler, and so a history, of its own.
static BOOL upscaleTemporal(id<MTLCommandBuffer> buffer, NSDictionary *inputs, id<MTLTexture> destination, NSString *view = nil) {
    id<MTLTexture> color = inputs[@"color"], depth = inputs[@"depth"], motion = inputs[@"motion"];
    if (!color || !depth || !motion || !destination) {
        failTemporal(@"The scene capture did not provide color, depth, motion, and final output textures.");
        return NO;
    }
    BG3MFXFrameParameters parameters = {};
    NSString *reason = nil;
    if (!temporalParameters(inputs,&parameters,&reason)) { failTemporal(reason); return NO; }
    BOOL nativeAAWarmup = [inputs[@"nativeTAAPreserved"] boolValue];
    bool pendingReset = temporalResetPending.exchange(false);
    parameters.reset |= nativeAAWarmup || pendingReset;
    if (pendingReset && view) BG3MFXResetTemporalHistory();  // every view restarts, not only the first to see it
    NSString *size = scalerKey(buffer.device,color.width,color.height,destination.width,destination.height);
    NSString *key = view ? [size stringByAppendingFormat:@"@%@",view] : size;
    BG3MFXTemporalUpscaler *upscaler;
    { std::lock_guard<std::recursive_mutex> lock(guard()); upscaler = temporalUpscalerCache()[key]; }
    NSError *error = nil;
    if (!upscaler) {
        upscaler = [[BG3MFXTemporalUpscaler alloc] initWithDevice:buffer.device inputWidth:color.width
            inputHeight:color.height outputWidth:destination.width outputHeight:destination.height error:&error];
        if (upscaler) {
            upscaler.gpuFailureHandler=^(NSError *gpuError) {
                failTemporal(gpuError.localizedDescription ?: @"Metal 4 could not complete temporal scaling commands.");
            };
#if !defined(BG3MFX_NO_TRACE) || defined(BG3MFX_STANDALONE_TEST_HOOKS)
            temporalScalersCreated.fetch_add(1);
#endif
            record(@{@"event":@"temporalScalerCreated",@"api":upscaler.usesMetal4 ? @"metal4" : @"metal3"});
            std::lock_guard<std::recursive_mutex> lock(guard());
            // Keep every settled size that leaks: evicting it freed nothing,
            // and a bounded cache once evicted the scaler it had just added,
            // recreating it every frame until the ANE was exhausted.
            temporalUpscalerCache()[key] = upscaler;
        }
    }
    if (upscaler) {
        // When the size changes, the previous size's scalers let go of what they
        // kept for their next frame (BG3 frees those render targets on resize),
        // and other sizes MetalFX does free are evicted. The current size is
        // never evicted. A split-screen frame's views, one scaler each and
        // called in turn, form one group: the whole frame's size.
        static NSString *activeGroup;
        id<MTLTexture> frame = inputs[@"scaled"] ?: destination;
        NSString *group = view ? [NSString stringWithFormat:@"split:%lux%lu",(unsigned long)frame.width,(unsigned long)frame.height] : size;
        NSMutableArray<BG3MFXTemporalUpscaler *> *idle = [NSMutableArray array];
        { std::lock_guard<std::recursive_mutex> lock(guard());
          temporalUpscalerGroups()[key] = group;
          if (![group isEqualToString:activeGroup]) {
              for (NSString *cached in temporalUpscalerCache().allKeys) {
                  BG3MFXTemporalUpscaler *other = temporalUpscalerCache()[cached];
                  NSString *cachedGroup = temporalUpscalerGroups()[cached] ?: cached;
                  if (activeGroup && [cachedGroup isEqualToString:activeGroup]) [idle addObject:other];
                  if (![cachedGroup isEqualToString:group] && other.outputHeight > TemporalLeakedOutputHeight) {
                      [temporalUpscalerCache() removeObjectForKey:cached];
                      [temporalUpscalerGroups() removeObjectForKey:cached];
                  }
              }
              activeGroup = group;
          } }
        for (BG3MFXTemporalUpscaler *previous in idle) [previous releaseIdleResources];
    }
    #ifndef BG3MFX_NO_TRACE
    validateMotionSample(buffer,motion);
#endif
    BOOL encoded = upscaler && [upscaler encodeColor:color deviceDepth:depth motion:motion parameters:parameters
        destination:destination commandBuffer:buffer error:&error];
    if (encoded) {
        if(frameGeneration(buffer) && !view) {
            NSMutableDictionary *frames=objc_getAssociatedObject(buffer,&temporalFrameKey);
            frames[[NSValue valueWithPointer:(__bridge const void *)destination]]=inputs;
        }
        rememberUpscaledTAA(inputs[@"nativeTAA"]);
        // Discovery frames contain native AA. Do not carry that filtered
        // history into the subsequent raw-jittered-color reconstruction.
        if (nativeAAWarmup) [upscaler resetHistory];
    }
    record(@{@"event":@"temporalUpscaleEncoded",@"success":@(encoded),@"input":texture(color),
        @"depth":texture(depth),@"motion":texture(motion),@"destination":texture(destination),@"error":error.description ?: @""});
    if (encoded) [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
#ifndef BG3MFX_NO_TRACE
        static std::atomic<unsigned> frames{0};
        unsigned frame = frames.fetch_add(1);
        if (frame < 3 || frame % 120 == 0)
            record(@{@"event":@"temporalValidationProgress",@"frame":@(frame),@"status":@(completed.status),@"input":texture(color)});
#endif
        record(@{@"event":@"temporalUpscaleCompleted",@"status":@(completed.status),
            @"error":completed.error.localizedDescription ?: @"",@"input":texture(color),@"destination":texture(destination)});
        if (completed.status != MTLCommandBufferStatusCompleted)
            failTemporal(completed.error.localizedDescription ?: @"Metal could not complete temporal scaling commands.");
    }];
    else failTemporal(error.localizedDescription ?: @"MetalFX could not encode the temporal frame.");
    return encoded;
}
static BOOL copyTemporalAAColor(id<MTLCommandBuffer> buffer, NSDictionary *inputs) {
    id<MTLTexture> color = inputs[@"color"], target = inputs[@"taaColor"];
    if (!color || !target || color.width != target.width || color.height != target.height ||
        color.pixelFormat != target.pixelFormat || target.storageMode == MTLStorageModeMemoryless ||
        color.hazardTrackingMode == MTLHazardTrackingModeUntracked || target.hazardTrackingMode == MTLHazardTrackingModeUntracked) {
        failTemporal(@"The native TAA output cannot safely receive the current HDR frame.");
        return NO;
    }
    if (color == target) return YES;
    id<MTLBlitCommandEncoder> encoder = [buffer blitCommandEncoder];
    if (!encoder) { failTemporal(@"Could not create the TAA replacement copy encoder."); return NO; }
    [encoder copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(color.width,color.height,1) toTexture:target destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0,0,0)];
    [encoder endEncoding];
    record(@{@"event":@"temporalTAACopy",@"source":texture(color),@"target":texture(target)});
    return YES;
}
// With sharpening, MetalFX writes an intermediate that BG3's own RCAS then
// sharpens into the final target (see Sharpening.h); nil keeps the direct write.
static char viewIntermediatesKey;
static id<MTLTexture> sharpeningIntermediate(id<MTLCommandBuffer> buffer, NSDictionary *inputs) {
    if (!BG3MFXSharpeningEnabled() || !inputs[@"rcas"] || !inputs[@"scaled"] || !inputs[@"destination"]) return nil;
    if (!inputs[@"view"])
        return [[BG3MFXNativeSharpening sharedForDevice:buffer.device] intermediateLike:inputs[@"destination"] commandBuffer:buffer];
    // BG3 runs RCAS over the whole frame for each split-screen view. The views
    // share one intermediate; each view's replay covers its own rectangle (see
    // sharpenInto), and the last one, like BG3's, every view's current result.
    NSMutableDictionary *shared = objc_getAssociatedObject(buffer,&viewIntermediatesKey);
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)inputs[@"destination"]];
    if (id<MTLTexture> texture = shared[key]) return texture;
    id<MTLTexture> texture = [[BG3MFXNativeSharpening sharedForDevice:buffer.device] intermediateLike:inputs[@"destination"] commandBuffer:buffer];
    if (!texture) return nil;
    if (!shared) { shared = [NSMutableDictionary dictionary]; objc_setAssociatedObject(buffer,&viewIntermediatesKey,shared,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    shared[key] = texture;
    return texture;
}
// One split-screen view: crops its inputs, upscales them with `upscale` into a
// view-sized output, and places that into the view's rectangle of `target`.
static BOOL upscaleView(id<MTLCommandBuffer> buffer, NSDictionary *inputs, NSArray<NSString *> *crops, id<MTLTexture> target,
                        BOOL (^upscale)(NSDictionary *cropped, id<MTLTexture> output)) {
    BG3MFXViewRegions *regions = [BG3MFXViewRegions sharedForDevice:buffer.device];
    NSArray *view = inputs[@"view"], *outputView = inputs[@"outputView"];
    if (!regions || !view || !outputView || !target) return NO;
    NSMutableDictionary *cropped = [inputs mutableCopy];
    for (NSString *name in crops) {
        id<MTLTexture> copy = [regions copyRegion:BG3MFXViewRegion(view) of:inputs[name] commandBuffer:buffer];
        if (!copy) return NO;
        cropped[name] = copy;
    }
    MTLRegion out = BG3MFXViewRegion(outputView);
    id<MTLTexture> output = [regions textureWidth:out.size.width height:out.size.height format:target.pixelFormat commandBuffer:buffer];
    return output && upscale(cropped,output) && [regions place:output into:target at:out.origin commandBuffer:buffer];
}
static void sharpenInto(id<MTLCommandBuffer> buffer, NSDictionary *inputs, id<MTLTexture> linear) {
    id<MTLTexture> destination = inputs[@"destination"];
    // A split-screen view's pass only has to produce its own rectangle: BG3
    // tone-maps each view right after its RCAS. A dispatch starts at the origin,
    // so its grid shrinks to the rectangle's far corner (the left view, half).
    NSArray *outputView = inputs[@"outputView"];
    MTLRegion region = outputView ? BG3MFXViewRegion(outputView) : MTLRegionMake2D(0,0,destination.width,destination.height);
    BOOL encoded = [[BG3MFXNativeSharpening sharedForDevice:buffer.device] encodeFrom:linear
        rcas:inputs[@"rcas"] destination:destination region:region commandBuffer:buffer
        dispatch:^(id<MTLComputeCommandEncoder> encoder, NSDictionary *rcas, MTLSize extent) {
            NSArray *g = rcas[@"grid"], *n = rcas[@"threads"];
            MTLSize grid = MTLSizeMake([g[0] unsignedIntegerValue],[g[1] unsignedIntegerValue],[g[2] unsignedIntegerValue]);
            // Each grid unit covers destination / grid pixels or more.
            if (extent.width < destination.width && grid.width)
                grid.width = std::min(grid.width, (extent.width * grid.width + destination.width - 1) / destination.width);
            if (extent.height < destination.height && grid.height)
                grid.height = std::min(grid.height, (extent.height * grid.height + destination.height - 1) / destination.height);
            MTLSize threads = MTLSizeMake([n[0] unsignedIntegerValue],[n[1] unsignedIntegerValue],[n[2] unsignedIntegerValue]);
            SEL dispatch = [rcas[@"threadgroups"] boolValue] ? @selector(dispatchThreadgroups:threadsPerThreadgroup:) : @selector(dispatchThreads:threadsPerThreadgroup:);
            // BG3's own pipeline: straight to Metal, not through the FSR replacement.
            ((void(*)(id,SEL,MTLSize,MTLSize))original(encoder,dispatch))(encoder,dispatch,grid,threads);
        }];
    if (encoded) return;
    record(@{@"event":@"sharpeningSkipped",@"destination":texture(destination)});
    id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
    [blit copyFromTexture:linear toTexture:destination];
    [blit endEncoding];
}
static void endEncoder(id self, SEL cmd) {
    id<MTLCommandBuffer> commandBuffer = encoderBuffer(self);
    __unsafe_unretained BG3MFXEncoderState *encoderRecord = encoderState(self);
    // Only keys this encoder may hold are read and cleared (most hold none).
    uint16_t associations = encoderAssociations(encoderRecord);
    NSDictionary *probeInputs = associations & AssocTAAInputs ? objc_getAssociatedObject(self, &taaInputsKey) : nil;
    NSDictionary *fsrInputs = associations & AssocFSRInputs ? objc_getAssociatedObject(self, &fsrInputsKey) : nil;
    NSDictionary *temporalInputs = probeInputs;
    NSDictionary *postprocess = associations & AssocPostprocess ? objc_getAssociatedObject(self,&temporalPostprocessKey) : nil;
    if (labEnabled && encoderRecord && encoderRecord->labRecord) {
        NSString *encoderLabel = [self label];
        std::lock_guard<std::recursive_mutex> lock(guard());
        if (encoderLabel.length) encoderRecord->labRecord[@"label"] = encoderLabel;
        if (encoderRecord->hasViewport) { MTLViewport v = encoderRecord->viewport;
            encoderRecord->labRecord[@"viewport"] = labRect(v.originX,v.originY,v.width,v.height); }
    }
    // A recognized pass followed by an unrecognized draw in the same encoder, or
    // an encoder of only unrecognized draws, overwrites its target: drop any
    // scene association for it (the per-draw logic this replaces did the same).
    if (encoderRecord && encoderRecord->lastDrawOther && metalFXEnabled && encoderRecord->colorTarget) {
        if (sceneTracked(encoderScalingMode(self),commandBuffer)) postprocess = @{@"target":encoderRecord->colorTarget};
    }
    NSDictionary *composition=nil;
    if (associations & AssocComposition) {
        composition=objc_getAssociatedObject(self,&frameCompositionKey);
        objc_setAssociatedObject(self,&frameCompositionKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
#ifndef BG3MFX_NO_TRACE
    NSArray *waterfallCopies=nil;
    if (associations & AssocWaterfall) {
        waterfallCopies=[objc_getAssociatedObject(self,&waterfallCopiesKey) copy];
        objc_setAssociatedObject(self,&waterfallCopiesKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
#endif
    BOOL replaceTAA = associations & AssocSuppressed ? [objc_getAssociatedObject(self,&temporalSuppressedKey) boolValue] : NO;
#ifndef BG3MFX_NO_TRACE
    if (getenv("BG3MFX_TRACE_TEMPORAL_CHAIN") && commandBuffer && sceneTracked(encoderScalingMode(self),commandBuffer)) {
        NSMutableArray *history = objc_getAssociatedObject(commandBuffer,&temporalPassHistoryKey);
        if (!history) {
            history = [NSMutableArray array];
            objc_setAssociatedObject(commandBuffer,&temporalPassHistoryKey,history,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [history addObject:@{@"pipeline":pipelineDescription(self) ?: @{},
            @"bindings":[objc_getAssociatedObject(self,&bindingsKey) copy] ?: @{},
            @"attachments":objc_getAssociatedObject(self,&attachmentsKey) ?: @{},@"replacedTAA":@(replaceTAA)}];
        if (history.count > 64) [history removeObjectAtIndex:0];
    }
#endif
    // The driver may recycle this encoder immediately when MetalFX work starts.
    // Consume the request before any nested Metal call, including creation paths
    // displaced by later instrumentation which no longer run instrumentEncoder.
    if (associations & AssocFSRInputs) objc_setAssociatedObject(self, &fsrInputsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (encoderRecord) encoderRecord->buffer = nil;
    if (associations & AssocSuppressed) objc_setAssociatedObject(self, &temporalSuppressedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (associations & AssocPostprocess) objc_setAssociatedObject(self, &temporalPostprocessKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    record(@{@"event": @"encoderEnd", @"pipeline": pipelineDescription(self) ?: @{},
             @"bindings": objc_getAssociatedObject(self, &bindingsKey) ?: @{},
             @"attachments": objc_getAssociatedObject(self, &attachmentsKey) ?: @{}});
    if (traceConstants) {
        std::lock_guard<std::recursive_mutex> lock(guard());
        NSDictionary *state = pipelineDescription(self);
        NSString *fragment = state[@"fragment"] ?: @"";
        if (diagnostics && ([fragment isEqualToString:@"PPTAA_PS"] || [fragment isEqualToString:@"VelocityBufferCamera_PS"] ||
             [fragment isEqualToString:@"BG3MFXConstantsSmoke"]) && [constantSamples[fragment] unsignedIntegerValue] < 8) {
            NSUInteger sample = [constantSamples[fragment] unsignedIntegerValue];
            constantSamples[fragment] = @(sample+1);
            NSMutableDictionary *snapshots = [NSMutableDictionary dictionary];
            [constantBindings(self) enumerateKeysAndObjectsUsingBlock:^(NSString *slot, NSDictionary *binding, BOOL *) {
                NSDictionary *sizes = shaderBufferSizes[fragment];
                NSNumber *declaredSize = sizes[slot];
                if (sizes && !declaredSize) return;
                NSUInteger limit = declaredSize ? MIN(declaredSize.unsignedIntegerValue,4096) : 4096;
                NSData *data = binding[@"bytes"];
                id<MTLBuffer> buffer = binding[@"buffer"];
                NSUInteger offset = [binding[@"offset"] unsignedIntegerValue];
                NSUInteger length = [binding[@"length"] unsignedIntegerValue];
                if (buffer) {
                    length = offset <= buffer.length ? buffer.length-offset : 0;
                    if (buffer.storageMode == MTLStorageModeShared && length && buffer.contents)
                        data = [NSData dataWithBytes:(const uint8_t *)buffer.contents+offset length:MIN(length,limit)];
                }
                if (data.length > limit) data = [data subdataWithRange:NSMakeRange(0,limit)];
                snapshots[slot] = @{@"offset": @(offset), @"availableLength": @(length),
                    @"capturedLength": @(data.length), @"base64": [data base64EncodedStringWithOptions:0] ?: @"",
                    @"storage": buffer ? @(buffer.storageMode) : @(-1)};
            }];
            record(@{@"event": @"shaderConstants", @"pipeline": state, @"sample": @(sample), @"bindings": snapshots});
        }
        // Release buffer references as soon as this encoder ends.
        if (encoderRecord) { for (auto &stage:encoderRecord->constants) for (auto &binding:stage) binding={}; encoderRecord->bytes=nil; }
    }
    if (labEnabled && labSerialize && commandBuffer) {
        id<MTLFence> fence = labFence(commandBuffer.device);
        if ([self respondsToSelector:@selector(updateFence:afterStages:)])
            [(id<MTLRenderCommandEncoder>)self updateFence:fence afterStages:MTLRenderStageFragment];
        else if ([self respondsToSelector:@selector(updateFence:)]) [(id<MTLComputeCommandEncoder>)self updateFence:fence];
    }
    ((void(*)(id,SEL))original(self,cmd))(self,cmd);
    if (labEnabled && labDumpCaptured && commandBuffer) labWriteDumps(commandBuffer,self);
#ifndef BG3MFX_NO_TRACE
    finishWaterfallCopies(commandBuffer,waterfallCopies);
#endif
    if (postprocess && commandBuffer) {
        NSMutableDictionary *sceneFrames = objc_getAssociatedObject(commandBuffer,&temporalFrameKey);
        id<MTLTexture> target = postprocess[@"target"];
        NSValue *targetKey = [NSValue valueWithPointer:(__bridge const void *)target];
        // Any render write invalidates a previous association with this target.
        // Forward only explicitly identified HDR scene-color passes, never a
        // same-size texture selected by a heuristic.
        [sceneFrames removeObjectForKey:targetKey];
        NSDictionary *inputFrame = postprocess[@"frame"];
        if ([postprocess[@"keep"] boolValue]) {
            // In-place scene pass: the target keeps the frame inputs it already had.
            sceneFrames[targetKey] = inputFrame;
            record(@{@"event":@"temporalColorKept",@"pipeline":postprocess[@"pipeline"],@"target":texture(target)});
        } else if (inputFrame) {
            if (!sceneFrames) {
                // A Spatial frame seeded at FSR_Tonemap has no earlier association.
                sceneFrames = [NSMutableDictionary dictionary];
                objc_setAssociatedObject(commandBuffer,&temporalFrameKey,sceneFrames,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            NSMutableDictionary *next = [inputFrame mutableCopy];
            next[@"taaColor"] = target;
            next[@"color"] = postprocess[@"tonemap"] ? postprocess[@"source"] : target;
            sceneFrames[targetKey] = next;
            record(@{@"event":@"temporalColorForwarded",@"pipeline":postprocess[@"pipeline"],
                @"source":texture(postprocess[@"source"]),@"target":texture(target)});
        }
    }
    if (metalFXEnabled && temporalInputs && commandBuffer && !temporalFailed) {
        BOOL temporalMode = encoderScalingMode(self) == 3;
        // Every mode but Temporal keeps native TAA; its output seeds the chain.
        BOOL spatialMode = !temporalMode && sceneTracked(encoderScalingMode(self),commandBuffer) && !replaceTAA;
        if (spatialMode) {
            NSMutableDictionary *frames = objc_getAssociatedObject(commandBuffer,&temporalFrameKey);
            if (!frames) {
                frames = [NSMutableDictionary dictionary];
                objc_setAssociatedObject(commandBuffer,&temporalFrameKey,frames,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            frames[[NSValue valueWithPointer:(__bridge const void *)temporalInputs[@"taaColor"]]] = temporalInputs;
        }
        if (temporalMode && (!replaceTAA || copyTemporalAAColor(commandBuffer,temporalInputs))) {
            labRecord(@{@"event":@"temporalFrameStored",@"taaColor":texture(temporalInputs[@"taaColor"]),@"view":temporalInputs[@"view"] ?: @[]});
            NSMutableDictionary *frames = objc_getAssociatedObject(commandBuffer,&temporalFrameKey);
            if (!frames) {
                frames = [NSMutableDictionary dictionary];
                objc_setAssociatedObject(commandBuffer,&temporalFrameKey,frames,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            frames[[NSValue valueWithPointer:(__bridge const void *)temporalInputs[@"taaColor"]]] = temporalInputs;
        }
    }
    int replacementMode = [fsrInputs[@"mode"] intValue];
    if (replacementMode == 2 && fsrInputs && commandBuffer && !spatialFailed) {
        id<MTLTexture> intermediate = sharpeningIntermediate(commandBuffer,fsrInputs);
        NSMutableDictionary *spatialInputs = [fsrInputs mutableCopy];
        if (intermediate) spatialInputs[@"destination"] = intermediate;
        BOOL upscaled = NO;
        if (!fsrInputs[@"destination"])
            failSpatial(@"The FSR dispatch sequence ended before a MetalFX output was identified.");
        else if (fsrInputs[@"view"]) {
            NSMutableDictionary *viewInputs = [fsrInputs mutableCopy];
            upscaled = upscaleView(commandBuffer,viewInputs,@[@"input"],intermediate ?: fsrInputs[@"destination"],
                ^BOOL(NSDictionary *cropped, id<MTLTexture> output) {
                    NSMutableDictionary *single = [cropped mutableCopy]; single[@"destination"] = output;
                    return upscaleSpatial(commandBuffer,single);
                });
            if (!upscaled && !spatialFailed) failSpatial(@"Could not upscale a split-screen view.");
        } else upscaled = upscaleSpatial(commandBuffer,spatialInputs);
        if (upscaled) {
            if (intermediate) sharpenInto(commandBuffer,fsrInputs,intermediate);
            rememberUpscaledTAA(fsrInputs[@"nativeTAA"]);
            // As Temporal does, attach the frame's inputs to the upscaled output
            // so the tone-mapping chain carries them to BG3's composition.
            NSMutableDictionary *frames = objc_getAssociatedObject(commandBuffer,&temporalFrameKey);
            NSDictionary *frame = frames[[NSValue valueWithPointer:(__bridge const void *)fsrInputs[@"encodedInput"]]];
            if (frameGeneration(commandBuffer) && frame[@"depth"])
                frames[[NSValue valueWithPointer:(__bridge const void *)fsrInputs[@"destination"]]] = frame;
        }
    }
    if (replacementMode == 3 && fsrInputs && commandBuffer && !temporalFailed) {
        id<MTLTexture> destination = fsrInputs[@"destination"];
        NSMutableDictionary *frames = objc_getAssociatedObject(commandBuffer,&temporalFrameKey);
        NSValue *key = [NSValue valueWithPointer:(__bridge const void *)fsrInputs[@"input"]];
        NSDictionary *frame = frames[key];
        [frames removeObjectForKey:key];
        // Native FSR was already skipped for this frame, so it cannot run now;
        // leave the previous output for this one frame and restart history.
        if (!destination) { temporalResetPending=true;
            record(@{@"event":@"metalFXFrameSkipped",@"reason":@"The FSR stage ended before its final output texture was identified."}); }
        else if (!frame) { temporalResetPending=true;
            record(@{@"event":@"metalFXFrameSkipped",@"reason":@"The temporal scaler did not receive a matching scene color, depth, and motion frame."}); }
        else {
            id<MTLTexture> intermediate = sharpeningIntermediate(commandBuffer,fsrInputs);
            BOOL upscaled;
            if (fsrInputs[@"view"]) {
                NSMutableDictionary *viewInputs = [frame mutableCopy];
                viewInputs[@"view"] = fsrInputs[@"view"]; viewInputs[@"outputView"] = fsrInputs[@"outputView"];
                NSString *tag = [NSString stringWithFormat:@"%@,%@",fsrInputs[@"view"][0],fsrInputs[@"view"][1]];
                upscaled = upscaleView(commandBuffer,viewInputs,@[@"color",@"depth",@"motion"],intermediate ?: destination,
                    ^BOOL(NSDictionary *cropped, id<MTLTexture> output) { return upscaleTemporal(commandBuffer,cropped,output,tag); });
                if (!upscaled && !temporalFailed) failTemporal(@"Could not upscale a split-screen view.");
            } else upscaled = upscaleTemporal(commandBuffer,frame,intermediate ?: destination);
            if (upscaled && intermediate) {
                sharpenInto(commandBuffer,fsrInputs,intermediate);
                // Frame Generation follows the frame from the texture MetalFX wrote.
                NSValue *written = [NSValue valueWithPointer:(__bridge const void *)intermediate];
                if (NSDictionary *generated = frames[written]) {
                    frames[[NSValue valueWithPointer:(__bridge const void *)destination]] = generated;
                    [frames removeObjectForKey:written];
                }
            }
        }
    }
    if(composition && commandBuffer) encodeGeneratedPair(commandBuffer,composition);
    if (sceneProbe && probeInputs && commandBuffer) probeScene(commandBuffer,probeInputs);
    if (encoderRecord) for (auto &texture:encoderRecord->textures) texture=nil;
    // Nested Metal work above may have set keys again: use the current bits.
    associations = encoderAssociations(encoderRecord);
    if (associations & AssocTAAInputs) objc_setAssociatedObject(self, &taaInputsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (encoderRecord) encoderRecord->colorTarget=nil;
    forgetEncoder(self);
    if (associations & AssocFSRInputs) objc_setAssociatedObject(self, &fsrInputsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void pipeline(__unsafe_unretained id self, SEL cmd, __unsafe_unretained id state) {
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(self);
    if (!(bindDedup && s && !BG3MFXBindFilter::forwardPipeline(s->pipeline,state)))
        ((void(*)(id,SEL,id))original(self,cmd))(self,cmd,state);
#ifndef BG3MFX_NO_TRACE
    if (redundantProbe && s) {
        ++redundantCounts[PipelineBinds];
        if (s->seenPipeline==state) ++redundantCounts[PipelineBindsRedundant];
        s->seenPipeline=state;
    }
#endif
    __unsafe_unretained BG3MFXPipelineInfo *info = state ? (__bridge BG3MFXPipelineInfo *)pipelineInfoPointer(state) : nil;
    NSDictionary *description = info ? info->description : nil;
    if (diagnostics && !description) description = @{@"label": [state label] ?: @""};
    if (s) {
        s->pipeline=state; s->description=description;
        s->kind=info ? info->kind : PipelineOther;
        s->prepass.pipeline=info && prepassTrim ? info->trim : TrimNone;
        if (labEnabled) {
            unsigned rules = state ? labRules(state) : 0;
            s->labPipeline=objc_getAssociatedObject(state,&labNameKey); s->labSkip=rules & 1; s->labWatch=rules & 2; s->labPoke=rules & 4;
        }
    }
    record(@{@"event": NSStringFromSelector(cmd), @"encoder": [self label] ?: @"", @"pipeline": description});
}
static BOOL cameraShader(MTLRenderPipelineDescriptor *desc) {
    NSString *name = desc.fragmentFunction.name;
    if (compositionShader(name)) return YES;
    return diagnostics && traceConstants && ([name isEqualToString:@"PPTAA_PS"] || [name isEqualToString:@"VelocityBufferCamera_PS"] ||
                              [name isEqualToString:@"BG3MFXConstantsSmoke"]);
}
static NSArray *structMembers(MTLStructType *type, NSUInteger depth) {
    NSMutableArray *members = [NSMutableArray array];
    if (depth > 3) return members;
    for (MTLStructMember *member in type.members) {
        NSMutableDictionary *entry = [@{@"name": member.name ?: @"", @"offset": @(member.offset), @"type": @(member.dataType)} mutableCopy];
        if (member.dataType == MTLDataTypeStruct) entry[@"members"] = structMembers(member.structType,depth+1);
        [members addObject:entry];
    }
    return members;
}
static void recordReflection(MTLRenderPipelineDescriptor *desc, MTLRenderPipelineReflection *reflection) {
    if (!reflection) return;
    NSMutableArray *buffers = [NSMutableArray array];
    NSMutableArray *textures = [NSMutableArray array];
    NSMutableDictionary *sizes = [NSMutableDictionary dictionary];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (MTLArgument *arg in reflection.fragmentArguments) {
        if (arg.type == MTLArgumentTypeBuffer) {
            sizes[[NSString stringWithFormat:@"fragment:%lu", (unsigned long)arg.index]] = @(arg.bufferDataSize);
            [buffers addObject:@{@"name": arg.name ?: @"", @"index": @(arg.index), @"size": @(arg.bufferDataSize),
                                 @"active": @(arg.active), @"members": structMembers(arg.bufferStructType,0)}];
        }
        if (arg.type == MTLArgumentTypeTexture)
            [textures addObject:@{@"name": arg.name ?: @"", @"index": @(arg.index), @"active": @(arg.active)}];
    }
#pragma clang diagnostic pop
    { std::lock_guard<std::recursive_mutex> lock(guard());
      shaderBufferSizes[desc.fragmentFunction.name ?: @""] = sizes; }
    record(@{@"event": @"shaderReflection", @"fragment": desc.fragmentFunction.name ?: @"", @"buffers": buffers, @"textures": textures});
}
static id renderPipeline(id self, SEL cmd, MTLRenderPipelineDescriptor *desc, NSError **error) {
    // The fixed fog composite is created like any pipeline; the game's own pair is the fallback.
    if (MTLRenderPipelineDescriptor *fog = BG3MFXSplitScreenFogDescriptor(self,desc))
        if (id state = renderPipeline(self,cmd,fog,nullptr)) {
            record(@{@"event": @"splitScreenFog", @"fragment": desc.fragmentFunction.name ?: @""});
            return state;
        }
    id state;
    if (cameraShader(desc)) {
        SEL optionsSelector = sel_registerName("newRenderPipelineStateWithDescriptor:options:reflection:error:");
        MTLRenderPipelineReflection *reflection = nil;
        NSError *reflectionError = nil;
        state = ((id(*)(id,SEL,id,MTLPipelineOption,MTLRenderPipelineReflection **,NSError **))original(self,optionsSelector))
            (self,optionsSelector,desc,MTLPipelineOptionBindingInfo|MTLPipelineOptionBufferTypeInfo,&reflection,&reflectionError);
        if (state) {
            recordReflection(desc,reflection);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            if(compositionShader(desc.fragmentFunction.name))for(MTLArgument *arg in reflection.fragmentArguments)
                if(arg.type==MTLArgumentTypeBuffer && arg.index==0)objc_setAssociatedObject(state,&compositorSizeKey,@(arg.bufferDataSize),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#pragma clang diagnostic pop
        }
        else record(@{@"event": @"shaderReflectionFailed", @"fragment": desc.fragmentFunction.name ?: @"", @"error": reflectionError.description ?: @""});
        if (!state) state = ((id(*)(id,SEL,id,NSError **))original(self,cmd))(self,cmd,desc,error);
    } else state = ((id(*)(id,SEL,id,NSError **))original(self,cmd))(self,cmd,desc,error);
    NSString *fragment = desc.fragmentFunction.name;
    if (labEnabled) labTagPipeline(state,[NSString stringWithFormat:@"%@|%@",desc.vertexFunction.name ?: @"",fragment ?: @""],desc.vertexDescriptor);
    NSDictionary *description = diagnostics ? @{@"vertex": desc.vertexFunction.name ?: @"", @"fragment": fragment ?: @"", @"label": desc.label ?: @""} :
        (recognizedFragment(fragment) ? @{@"fragment":fragment} : nil);
#ifndef BG3MFX_NO_TRACE
    NSDictionary *waterfall=waterfallLayout(desc);
    if (waterfall) { NSMutableDictionary *expanded=[description mutableCopy]; expanded[@"vertexLayout"]=waterfall; description=expanded; }
#endif
    if (state) {
        BG3MFXPipelineInfo *info = [BG3MFXPipelineInfo new];
        info->description = description; info->kind = classifyPipeline(fragment);
        objc_setAssociatedObject(state, &pipelineKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pipelineGeneration.fetch_add(1, std::memory_order_release);
        if (prepassTrim) BG3MFXClassifyPrepass(desc,state,markPrepassPipeline);
    }
    record(@{@"event": @"renderPipeline", @"pipeline": description, @"success": @(state != nil)});
    return state;
}
static id renderPipelineOptions(id self, SEL cmd, MTLRenderPipelineDescriptor *desc, MTLPipelineOption options, MTLRenderPipelineReflection **reflection, NSError **error) {
    if (MTLRenderPipelineDescriptor *fog = BG3MFXSplitScreenFogDescriptor(self,desc))
        if (id state = renderPipelineOptions(self,cmd,fog,options,reflection,nullptr)) {
            record(@{@"event": @"splitScreenFog", @"fragment": desc.fragmentFunction.name ?: @""});
            return state;
        }
    MTLRenderPipelineReflection *extraReflection = nil;
    id state;
    if (cameraShader(desc)) {
        NSError *reflectionError = nil;
        state = ((id(*)(id,SEL,id,MTLPipelineOption,MTLRenderPipelineReflection **,NSError **))original(self,cmd))
            (self,cmd,desc,options|MTLPipelineOptionBindingInfo|MTLPipelineOptionBufferTypeInfo,&extraReflection,&reflectionError);
        if (state) {
            if (reflection) *reflection = extraReflection;
            recordReflection(desc,extraReflection);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            if(compositionShader(desc.fragmentFunction.name))for(MTLArgument *arg in extraReflection.fragmentArguments)
                if(arg.type==MTLArgumentTypeBuffer && arg.index==0)objc_setAssociatedObject(state,&compositorSizeKey,@(arg.bufferDataSize),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#pragma clang diagnostic pop
        } else state = ((id(*)(id,SEL,id,MTLPipelineOption,MTLRenderPipelineReflection **,NSError **))original(self,cmd))(self,cmd,desc,options,reflection,error);
    } else state = ((id(*)(id,SEL,id,MTLPipelineOption,MTLRenderPipelineReflection **,NSError **))original(self,cmd))(self,cmd,desc,options,reflection,error);
    NSString *fragment = desc.fragmentFunction.name;
    if (labEnabled) labTagPipeline(state,[NSString stringWithFormat:@"%@|%@",desc.vertexFunction.name ?: @"",fragment ?: @""],desc.vertexDescriptor);
    NSDictionary *description = diagnostics ? @{@"vertex": desc.vertexFunction.name ?: @"", @"fragment": fragment ?: @"", @"label": desc.label ?: @""} :
        (recognizedFragment(fragment) ? @{@"fragment":fragment} : nil);
#ifndef BG3MFX_NO_TRACE
    NSDictionary *waterfall=waterfallLayout(desc);
    if (waterfall) { NSMutableDictionary *expanded=[description mutableCopy]; expanded[@"vertexLayout"]=waterfall; description=expanded; }
#endif
    if (state) {
        BG3MFXPipelineInfo *info = [BG3MFXPipelineInfo new];
        info->description = description; info->kind = classifyPipeline(fragment);
        objc_setAssociatedObject(state, &pipelineKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pipelineGeneration.fetch_add(1, std::memory_order_release);
        if (prepassTrim) BG3MFXClassifyPrepass(desc,state,markPrepassPipeline);
    }
    record(@{@"event": @"renderPipeline", @"pipeline": description, @"success": @(state != nil)});
    return state;
}
static id computePipeline(id self, SEL cmd, id<MTLFunction> function, NSError **error) {
    id state = ((id(*)(id,SEL,id,NSError **))original(self,cmd))(self,cmd,function,error);
    NSString *name = function.name;
    labTagPipeline(state,name);
    NSDictionary *description = (diagnostics || [name isEqualToString:@"FSR"] || [name isEqualToString:@"FSR_RCAS"] ||
        [name isEqualToString:@"CAS"]) ? @{@"compute": name ?: @""} : nil;
    if (state) {
        BG3MFXPipelineInfo *info = [BG3MFXPipelineInfo new];
        info->description = description;
        objc_setAssociatedObject(state, &pipelineKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pipelineGeneration.fetch_add(1, std::memory_order_release);
    }
    record(@{@"event": @"computePipeline", @"pipeline": description, @"success": @(state != nil)});
    return state;
}
static NSData *constantBytes(id encoder, EncoderStage stage, NSUInteger index, NSUInteger count) {
    ConstantBinding *binding = constantSlot(encoder,stage,index);
    if (!binding) return nil;
    NSData *bytes = binding->hasBytes ? encoderState(encoder)->bytes[@(stage*EncoderSlots+index)] : nil;
    if (bytes.length >= count) return [bytes subdataWithRange:NSMakeRange(0,count)];
    id<MTLBuffer> buffer = binding->buffer;
    NSUInteger offset = binding->offset;
    if (!buffer || buffer.storageMode != MTLStorageModeShared || !buffer.contents ||
        offset > buffer.length || count > buffer.length-offset) return nil;
    return [NSData dataWithBytes:(const uint8_t *)buffer.contents+offset length:count];
}
#ifndef BG3MFX_NO_TRACE
// Whether worker drawables reach the display. CAMetalLayer drops a drawable
// superseded within the same refresh (presentedTime == 0).
// GPU time per frame-generation frame: Metal 4 submissions by label, and BG3's
// presenting command buffers (duration and spacing between completions).
static std::mutex gpuTimingLock;
static std::map<std::string,std::pair<double,unsigned>> gpuSubmissionTime;
static double frameGPUTime, frameGPUPeriod, lastFrameGPUEnd; static unsigned frameGPUCount;
static void recordGPUSubmission(NSString *label, double seconds) {
    std::lock_guard<std::mutex> hold(gpuTimingLock);
    auto &entry=gpuSubmissionTime[label.UTF8String ?: "?"]; entry.first+=seconds; ++entry.second;
}
static void recordFrameGPU(id<MTLCommandBuffer> buffer) {
    std::lock_guard<std::mutex> hold(gpuTimingLock);
    frameGPUTime+=buffer.GPUEndTime-buffer.GPUStartTime; ++frameGPUCount;
    if (lastFrameGPUEnd>0) frameGPUPeriod+=buffer.GPUEndTime-lastFrameGPUEnd;
    lastFrameGPUEnd=buffer.GPUEndTime;
}
static NSDictionary *takeGPUTiming() {
    std::lock_guard<std::mutex> hold(gpuTimingLock);
    NSMutableDictionary *result=[NSMutableDictionary dictionary];
    for (auto &[label,entry]:gpuSubmissionTime)
        result[[@(label.c_str()) stringByAppendingString:@" ms"]]=@(entry.second ? entry.first*1000/entry.second : 0);
    result[@"bg3FrameBufferMs"]=@(frameGPUCount ? frameGPUTime*1000/frameGPUCount : 0);
    result[@"bg3FrameGPUPeriodMs"]=@(frameGPUCount>1 ? frameGPUPeriod*1000/(frameGPUCount-1) : 0);
    gpuSubmissionTime.clear(); frameGPUTime=frameGPUPeriod=0; frameGPUCount=0;
    return result;
}
static void recordDisplayed(BOOL generated, CFTimeInterval time, CFTimeInterval target, double interval) {
    static std::mutex lock; static unsigned shown[2], dropped[2], missing[2], raw;
    static CFTimeInterval last; static BOOL lastGenerated;
    // Gaps are keyed by the frame that ended them: real->generated and
    // generated->real should each be about half the rendered interval.
    static std::vector<double> realToGenerated, generatedToReal, lateness[2], intervals;
    std::lock_guard<std::mutex> hold(lock);
    int kind=generated ? 1 : 0;
    if (time<0) missing[kind]++;
    else if (time==0) dropped[kind]++;
    else {
        shown[kind]++;
        if (last>0 && lastGenerated!=generated) (generated ? realToGenerated : generatedToReal).push_back(time-last);
        last=time; lastGenerated=generated;
        if (target>0) lateness[kind].push_back(time-target);
    }
    intervals.push_back(interval);
    if (raw++<120) record(@{@"event":@"frameGenerationDisplay",@"generated":@(generated),@"shown":@(time),
        @"target":@(target),@"intervalMs":@(interval*1000)});
    unsigned total=shown[0]+shown[1]+dropped[0]+dropped[1]+missing[0]+missing[1];
    if (total%240) return;
    auto ms=[](std::vector<double> v, double p){
        if (v.empty()) return 0.0; std::sort(v.begin(),v.end()); return 1000*v[(size_t)(p*(v.size()-1))]; };
    auto spread=[&](const std::vector<double> &v){ return @[@(ms(v,.1)),@(ms(v,.5)),@(ms(v,.9))]; };
    BG3MFXFramePresenter *presenter;
    { std::lock_guard<std::recursive_mutex> guardLock(guard()); presenter=framePresenter; }
    if (presenter)
        record(@{@"event":@"frameGenerationPresenterTiming",@"timing":[presenter takeTimingSummary],@"gpu":takeGPUTiming()});
    record(@{@"event":@"frameGenerationDisplayed",@"generatedShown":@(shown[1]),@"generatedDropped":@(dropped[1]),
        @"generatedNoDrawable":@(missing[1]),@"realShown":@(shown[0]),@"realDropped":@(dropped[0]),@"realNoDrawable":@(missing[0]),
        @"realToGeneratedMsP10P50P90":spread(realToGenerated),@"generatedToRealMsP10P50P90":spread(generatedToReal),
        @"generatedLateMsP10P50P90":spread(lateness[1]),@"realLateMsP10P50P90":spread(lateness[0]),
        @"renderedIntervalMsP10P50P90":spread(intervals)});
    realToGenerated.clear(); generatedToReal.clear(); lateness[0].clear(); lateness[1].clear(); intervals.clear();
}
#endif
static void encodeGeneratedPair(id<MTLCommandBuffer> buffer, NSDictionary *request) {
    id<MTLTexture> scene=request[@"scene"], ui=request[@"ui"], target=request[@"target"];
    // Only frames composed into a stand-in drawable can be paired. A frame that
    // began on a real drawable (Frame Generation just selected) stays native.
    BG3MFXFramePresenter *presenter;
    { std::lock_guard<std::recursive_mutex> lock(guard()); presenter=framePresenter; }
    if(![presenter ownsTexture:target]) return;
    NSDictionary *inputs=request[@"inputs"];
    id<MTLTexture> depth=inputs[@"depth"], motion=inputs[@"motion"];
    BG3MFXFrameParameters parameters={}; NSString *reason=nil;
    if(!temporalParameters(inputs,&parameters,&reason)) { declineFrameGeneration(reason); return; }
    NSString *configuration=[NSString stringWithFormat:@"%p:%lu:%lu:%lu:%lu:%d:%lu:%lu/%lu:%lu/%lu:%lu/%lu",(__bridge void *)buffer.device,
        depth.width,depth.height,scene.width,scene.height,[objc_getAssociatedObject(buffer,&bufferScalingModeKey) intValue],target.pixelFormat,
        scene.pixelFormat,scene.usage,depth.pixelFormat,depth.usage,motion.pixelFormat,motion.usage];
    NSError *error=nil;
    if(![configuration isEqualToString:frameConfiguration]) {
        frameInterpolator=[[BG3MFXFrameInterpolation alloc] initWithDevice:buffer.device scene:scene depth:depth motion:motion error:&error];
        if(!frameInterpolator) {declineFrameGeneration(error.localizedDescription ?: @"Could not initialize frame generation.");return;}
        frameInterpolator.failureHandler=^(NSError *e){declineFrameGeneration(e.localizedDescription ?: @"Metal could not complete frame generation.");};
        frameConfiguration=configuration;previousFrameTime=0;
        record(@{@"event":@"frameGenerationCreated",@"api":frameInterpolator.usesMetal4 ? @"metal4" : @"metal3",
            @"input":texture(depth),@"scene":texture(scene),@"direct":@[@(frameInterpolator.directColor),
            @(frameInterpolator.directDepth),@(frameInterpolator.directMotion)]});
    }
    if(frameGenerationResetPending.exchange(false)) { [frameInterpolator resetHistory]; previousFrameTime=0; }
    double now=NSProcessInfo.processInfo.systemUptime;
    double interval=previousFrameTime>0 ? now-previousFrameTime : 1.0/60;
    previousFrameTime=now;
    if(interval<=0 || interval>0.1) {parameters.reset=YES;interval=1.0/60;}
    encodingFrameGeneration=true;
    id<MTLTexture> interpolated=[frameInterpolator encodeScene:scene depth:depth motion:motion camera:inputs[@"camera"]
        parameters:parameters deltaTime:interval commandBuffer:buffer error:&error];
    if(!interpolated) {encodingFrameGeneration=false;declineFrameGeneration(error.localizedDescription ?: @"Could not encode the generated frame.");return;}
    // BG3's own CombineUI already composes the real frame into the stand-in;
    // compose only the generated scene with the same UI, pipeline and constants.
    id<MTLTexture> generated=[presenter generatedTargetLike:target];
    if(!generated){encodingFrameGeneration=false;declineFrameGeneration(@"Could not allocate the frame generation composition output.");return;}
    // Replay BG3's draw exactly: its viewport and scissor, and outside them the
    // real frame's pixels (letterbox bars, or whatever its load action left).
    MTLViewport viewport={0,0,double(target.width),double(target.height),0,1};
    MTLScissorRect scissor={0,0,target.width,target.height};
    NSData *viewportData=request[@"viewport"],*scissorData=request[@"scissor"];
    if(viewportData) memcpy(&viewport,viewportData.bytes,sizeof(viewport));
    if(scissorData) memcpy(&scissor,scissorData.bytes,sizeof(scissor));
    bool partial=viewport.originX>0 || viewport.originY>0 || viewport.originX+viewport.width<target.width ||
        viewport.originY+viewport.height<target.height || scissor.x>0 || scissor.y>0 ||
        scissor.x+scissor.width<target.width || scissor.y+scissor.height<target.height;
    if(partial) {
        auto blit=[buffer blitCommandEncoder];
        [blit copyFromTexture:target toTexture:generated];[blit endEncoding];
    }
    auto pass=[MTLRenderPassDescriptor new];pass.colorAttachments[0].texture=generated;
    pass.colorAttachments[0].loadAction=partial ? MTLLoadActionLoad : MTLLoadActionDontCare;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    auto e=[buffer renderCommandEncoderWithDescriptor:pass];
    [e setRenderPipelineState:request[@"pipeline"]];
    if(viewportData) [e setViewport:viewport];
    if(scissorData) [e setScissorRect:scissor];
    NSData *vertexBytes=request[@"vertexBytes"];
    if(vertexBytes) [e setVertexBytes:vertexBytes.bytes length:vertexBytes.length atIndex:0];
    else [e setVertexBuffer:request[@"vertices"] offset:[request[@"vertexOffset"] unsignedIntegerValue] atIndex:0];
    NSData *constants=request[@"constants"];[e setFragmentBytes:constants.bytes length:constants.length atIndex:0];
    [e setFragmentSamplerState:request[@"sampler"] atIndex:0];
    [e setFragmentTexture:interpolated atIndex:0];[e setFragmentTexture:ui atIndex:1];
    CompositionDraw draw;memcpy(&draw,[request[@"draw"] bytes],sizeof(draw));
    if(id<MTLBuffer> indices=request[@"indexBuffer"])
        [e drawIndexedPrimitives:draw.type indexCount:draw.count indexType:draw.indexType indexBuffer:indices
            indexBufferOffset:draw.indexOffset instanceCount:draw.instances baseVertex:draw.baseVertex baseInstance:draw.baseInstance];
    else [e drawPrimitives:draw.type vertexStart:draw.start vertexCount:draw.count instanceCount:draw.instances baseInstance:draw.baseInstance];
    [e endEncoding];
    encodingFrameGeneration=false;
    objc_setAssociatedObject(buffer,&generatedPairKey,@{@"generated":generated,@"presenter":presenter,
        @"interval":@(interval),@"target":target},OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    record(@{@"event":@"frameGenerationEncoded",@"scene":texture(scene),@"generated":texture(generated),@"reset":@(parameters.reset),
        @"interval":@(interval),@"mode":objc_getAssociatedObject(buffer,&bufferScalingModeKey) ?: @0,
        @"target":texture(target),@"buffer":@((uintptr_t)(__bridge void *)buffer)});
}

// The view this TAA draw renders, from BG3's Viewport constants: nil for the
// whole texture (also when there are no constants, as Spatial never needed
// them), [x, y, width, height] for one split-screen view. False when the
// viewport is neither (cropped or scaled views are not supported).
static bool sceneView(id encoder, id<MTLTexture> texture, NSArray **view) {
    *view = nil;
    NSData *viewport = constantBytes(encoder,StageFragment,9,168);
    if (!viewport || !texture) return true;
    const float *vp = (const float *)viewport.bytes;
    const uint32_t *size = (const uint32_t *)((const uint8_t *)viewport.bytes+16);
    const int32_t *minimum = (const int32_t *)((const uint8_t *)viewport.bytes+24);
    if (vp[0] == 1 && vp[1] == 1 && vp[2] == 0 && vp[3] == 0 && size[0] == texture.width && size[1] == texture.height) return true;
    // A split-screen view covers its share of the texture exactly.
    if (minimum[0] < 0 || minimum[1] < 0 || !size[0] || !size[1] ||
        minimum[0]+size[0] > texture.width || minimum[1]+size[1] > texture.height ||
        std::abs(vp[0]*texture.width-size[0]) > 1 || std::abs(vp[1]*texture.height-size[1]) > 1 ||
        std::abs(vp[2]*texture.width-minimum[0]) > 1 || std::abs(vp[3]*texture.height-minimum[1]) > 1) return false;
    *view = @[@(minimum[0]),@(minimum[1]),@(size[0]),@(size[1])];
    return true;
}
static void captureSceneInputs(id encoder, NSString *fragment) {
    std::lock_guard<std::recursive_mutex> lock(guard());
    if ((!sceneProbe && !metalFXEnabled) || (sceneProbe && sceneProbeAttempts && !metalFXEnabled)) return;
    id<MTLCommandBuffer> buffer = encoderBuffer(encoder);
    NSDictionary *textures = boundTextures(encoder);
    id<MTLTexture> target = encoderTarget(encoder);
    id<MTLTexture> source = textures[@"0"];
    if ([fragment isEqualToString:@"LinearizeDepth"] && source &&
        target.pixelFormat == MTLPixelFormatR32Float &&
        target.width == source.width &&
        target.height == source.height &&
        source.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 && buffer) {
        objc_setAssociatedObject(buffer, &deviceDepthKey, source, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if ([fragment isEqualToString:@"VelocityBufferCamera_PS"] && buffer) {
        NSData *camera = constantBytes(encoder,StageFragment,11,224);
        if (camera) {
            objc_setAssociatedObject(buffer,&sceneCameraKey,camera,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(buffer.commandQueue,&sceneCameraKey,camera,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    if (![fragment isEqualToString:@"PPTAA_PS"]) return;
    objc_setAssociatedObject(encoder, &taaInputsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id<MTLTexture> taaTarget = encoderTarget(encoder);
    NSDictionary *spatialSeed = nil;
    int mode = encoderScalingMode(encoder);
    if (mode != 3) {
        // Off, FSR and Spatial keep BG3's TAA. Seed the postprocess chain with
        // its output in linear HDR: Spatial upscales it, and Frame Generation
        // follows it to the composition.
        if (!buffer || !sceneTracked(mode,buffer) || !taaTarget || taaTarget.pixelFormat != MTLPixelFormatRG11B10Float) return;
        spatialSeed = @{@"color":taaTarget,@"taaColor":taaTarget,@"nativeTAA":taaTarget};
        NSArray *view = nil;
        if (!sceneView(encoder,taaTarget,&view)) return;
        if (view) spatialSeed = @{@"color":taaTarget,@"taaColor":taaTarget,@"nativeTAA":taaTarget,@"view":view};
        objc_setAssociatedObject(encoder, &taaInputsKey, spatialSeed, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        noteAssociation(encoder,AssocTAAInputs);
        // Frame Generation also needs this frame's depth, motion and camera,
        // validated exactly as for Temporal. Without them the frame still
        // renders and upscales; it just cannot be paired.
        if (!frameGeneration(buffer)) return;
    }
    id<MTLTexture> motion = textures[@"2"];
    id<MTLTexture> depth = objc_getAssociatedObject(buffer, &deviceDepthKey);
    BOOL resetMotion = motion.width == 16 && motion.height == 16 && motion.pixelFormat == MTLPixelFormatRGBA8Unorm;
    if (resetMotion && source && buffer) {
        // BG3 invalidates velocity/history for the first frame after a quality
        // change. MetalFX must start a fresh history with zero displacement.
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float width:source.width height:source.height mipmapped:NO];
        desc.storageMode = MTLStorageModeShared; desc.usage = MTLTextureUsageShaderRead;
        motion = [buffer.device newTextureWithDescriptor:desc];
        NSMutableData *zeros = [NSMutableData dataWithLength:source.width*source.height*4];
        [motion replaceRegion:MTLRegionMake2D(0,0,source.width,source.height) mipmapLevel:0 withBytes:zeros.bytes bytesPerRow:source.width*4];
    }
    if (!source || !motion || !depth || !taaTarget ||
        taaTarget.width != source.width || taaTarget.height != source.height || motion.pixelFormat != MTLPixelFormatRG16Float ||
        source.width != motion.width || source.height != motion.height ||
        source.width != depth.width || source.height != depth.height) {
        objc_setAssociatedObject(buffer,&sceneCaptureFailureKey,[NSString stringWithFormat:@"scene textures: color %lux%lu, motion %lux%lu format %lu, depth %lux%lu, target %lux%lu",(unsigned long)source.width,(unsigned long)source.height,(unsigned long)motion.width,(unsigned long)motion.height,(unsigned long)motion.pixelFormat,(unsigned long)depth.width,(unsigned long)depth.height,(unsigned long)taaTarget.width,(unsigned long)taaTarget.height],OBJC_ASSOCIATION_RETAIN_NONATOMIC); return;
    }
    NSData *camera = objc_getAssociatedObject(buffer,&sceneCameraKey) ?: constantBytes(encoder,StageFragment,11,224);
    if (!camera && resetMotion) camera = objc_getAssociatedObject(buffer.commandQueue,&sceneCameraKey);
    NSData *temporal = constantBytes(encoder,StageFragment,8,224);
    NSData *viewport = constantBytes(encoder,StageFragment,9,168);
    if (!camera || !temporal || !viewport) {
        objc_setAssociatedObject(buffer,&sceneCaptureFailureKey,[NSString stringWithFormat:@"constants: camera %@, jitter %@, viewport %@",camera ? @"available" : @"missing",temporal ? @"available" : @"missing",viewport ? @"available" : @"missing"],OBJC_ASSOCIATION_RETAIN_NONATOMIC); return;
    }
    NSArray *view = nil;
    if (!sceneView(encoder,source,&view)) { labRecord(@{@"event":@"sceneCaptureSkipped",@"reason":@"unsupported viewport"}); return; }
    // Frame Generation pairs whole frames only.
    if (spatialSeed && view) return;
    if (spatialSeed) {
        NSMutableDictionary *inputs = [spatialSeed mutableCopy];
        [inputs addEntriesFromDictionary:@{@"depth": depth, @"motion": motion, @"camera": camera, @"temporal": temporal, @"reset":@(resetMotion)}];
        objc_setAssociatedObject(encoder, &taaInputsKey, inputs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        noteAssociation(encoder,AssocTAAInputs);
        return;
    }
    NSMutableDictionary *inputs = [@{@"color": source, @"taaColor": taaTarget, @"nativeTAA":taaTarget,
          @"nativeTAAPreserved":@(!knownUpscaledTAA(taaTarget)),
          @"depth": depth, @"motion": motion, @"camera": camera, @"temporal": temporal, @"reset":@(resetMotion)} mutableCopy];
    if (view) inputs[@"view"] = view;
    objc_setAssociatedObject(encoder, &taaInputsKey, inputs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    noteAssociation(encoder,AssocTAAInputs);
    labRecord(@{@"event":@"temporalSceneCaptured",@"view":view ?: @[],@"taaColor":texture(taaTarget),@"color":texture(source)});
}
static id<MTLBuffer> probeReadback(id<MTLCommandBuffer> buffer, id<MTLTexture> outputTexture) {
    NSUInteger row = outputTexture.width * 8; // RGBA16Float, aligned for these scene dimensions.
    row = (row + 255) & ~NSUInteger(255);
    id<MTLBuffer> data = [buffer.device newBufferWithLength:row*outputTexture.height options:MTLResourceStorageModeShared];
    if (!data) return nil;
    id<MTLBlitCommandEncoder> encoder = [buffer blitCommandEncoder];
    [encoder copyFromTexture:outputTexture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(outputTexture.width,outputTexture.height,1) toBuffer:data destinationOffset:0
        destinationBytesPerRow:row destinationBytesPerImage:row*outputTexture.height];
    [encoder endEncoding];
    return data;
}
[[maybe_unused]] static NSDictionary *probeStatistics(id<MTLBuffer> data, id<MTLTexture> outputTexture) {
    if (!data) return @{};
    NSUInteger row = (outputTexture.width*8 + 255) & ~NSUInteger(255);
    NSUInteger samples=0, nonfinite=0, positive=0;
    float maximum=0;
    for (NSUInteger y=0; y<outputTexture.height; y+=17) for (NSUInteger x=0; x<outputTexture.width; x+=19) {
        const __fp16 *pixel = (const __fp16 *)((const uint8_t *)data.contents+y*row+x*8);
        for (int c=0; c<3; ++c) {
            float v = pixel[c]; ++samples;
            if (!std::isfinite(v)) ++nonfinite;
            else { if (v > 0) ++positive; maximum = std::fmax(maximum,v); }
        }
    }
    return @{@"sampledComponents": @(samples), @"nonfinite": @(nonfinite), @"positive": @(positive), @"maximum": @(maximum)};
}
static void probeScene(id<MTLCommandBuffer> buffer, NSDictionary *inputs) {
    // Claim the attempt under the lock, then release it before calling MetalFX.
    // Synchronous scaler initialization waits on workers which invoke our hooks.
    { std::lock_guard<std::recursive_mutex> lock(guard());
      if (sceneProbeAttempts) return;
      ++sceneProbeAttempts; }
    if (!buffer.retainedReferences) {
        record(@{@"event": @"sceneProbeSkipped", @"reason": @"BG3 uses an unretained command buffer; resource lifetime integration is required."});
        return;
    }
    id<MTLTexture> rawDepth = inputs[@"depth"];
    id<MTLTexture> color = inputs[@"color"], motion = inputs[@"motion"];
    // Metal forbids casting combined depth/stencil into a Depth32Float view.
    // Sample the original depth aspect and copy unchanged device depth to R32F.
    NSError *error = nil;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void BG3MFXCopyDepth(depth2d<float> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]], uint2 p [[thread_position_in_grid]]) {"
        "if (p.x >= dst.get_width() || p.y >= dst.get_height()) return;"
        "constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);"
        "dst.write(float4(src.sample(s, float2(p)+0.5)), p); }";
    id<MTLLibrary> library = [buffer.device newLibraryWithSource:source options:nil error:&error];
    id<MTLComputePipelineState> copy = library ? [buffer.device newComputePipelineStateWithFunction:[library newFunctionWithName:@"BG3MFXCopyDepth"] error:&error] : nil;
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
        width:rawDepth.width height:rawDepth.height mipmapped:NO];
    desc.storageMode = MTLStorageModePrivate;
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> depth = [buffer.device newTextureWithDescriptor:desc];
    if (!copy || !depth || !(rawDepth.usage & MTLTextureUsageShaderRead) ||
        rawDepth.hazardTrackingMode == MTLHazardTrackingModeUntracked) {
        record(@{@"event": @"sceneProbeSkipped", @"reason": @"Device depth copy could not be prepared safely.", @"error": error.description ?: @"", @"depth": texture(rawDepth)}); return;
    }
    const float *camera = (const float *)[inputs[@"camera"] bytes];
    const float *temporal = (const float *)[inputs[@"temporal"] bytes];
    BG3MFXFrameParameters p = {};
    BG3MFXApplyTemporalJitter(&p, temporal[52], temporal[53]);
    p.motionScaleX = p.motionScaleY = -1;
    p.depthReversed = YES; p.reset = YES;
    float nearPlane = camera[48], farPlane = camera[49];
    float nearDepth = camera[26] + camera[30]/nearPlane;
    float farDepth = camera[26] + camera[30]/farPlane;
    if (!std::isfinite(nearDepth) || !std::isfinite(farDepth) || std::abs(nearDepth-1) > 0.001 ||
        std::abs(farDepth) > 0.001 || nearPlane <= 0 || farPlane <= nearPlane ||
        !std::isfinite(p.jitterX) || !std::isfinite(p.jitterY) || std::abs(p.jitterX) > 0.5 || std::abs(p.jitterY) > 0.5) {
        record(@{@"event": @"sceneProbeSkipped", @"reason": @"Unexpected perspective camera or jitter constants."}); return;
    }
    BG3MFXPipeline *scaler = [[BG3MFXPipeline alloc] initWithDevice:buffer.device inputWidth:color.width inputHeight:color.height
        outputWidth:color.width*2 outputHeight:color.height*2 colorFormat:color.pixelFormat depthFormat:depth.pixelFormat
        motionFormat:motion.pixelFormat outputFormat:MTLPixelFormatRGBA16Float error:&error];
    if (!scaler) {
        record(@{@"event": @"sceneProbeFailed", @"error": error.description ?: @"Scaler creation failed"}); return;
    }
    id<MTLComputeCommandEncoder> encoder = [buffer computeCommandEncoder];
    [encoder setComputePipelineState:copy];
    [encoder setTexture:rawDepth atIndex:0]; [encoder setTexture:depth atIndex:1];
    [encoder dispatchThreads:MTLSizeMake(depth.width,depth.height,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
    [encoder endEncoding];
    BG3MFXFrame *frame = scaler ? [scaler encodeColor:color depth:depth motion:motion parameters:p commandBuffer:buffer error:&error] : nil;
    if (!frame) {
        record(@{@"event": @"sceneProbeFailed", @"error": error.description ?: @"unknown", @"color": texture(color), @"depth": texture(depth), @"motion": texture(motion)}); return;
    }
    [[maybe_unused]] id<MTLBuffer> temporalPixels = probeReadback(buffer,frame.rendered);
    id<MTLTexture> taaColor = inputs[@"taaColor"];
    BG3MFXPipeline *spatial = [[BG3MFXPipeline alloc] initWithDevice:buffer.device mode:BG3MFXScalingModeSpatial
        colorProcessingMode:MTLFXSpatialScalerColorProcessingModeHDR inputWidth:taaColor.width inputHeight:taaColor.height
        outputWidth:taaColor.width*2 outputHeight:taaColor.height*2 colorFormat:taaColor.pixelFormat
        depthFormat:MTLPixelFormatInvalid motionFormat:MTLPixelFormatInvalid outputFormat:MTLPixelFormatRGBA16Float error:&error];
    BG3MFXFrame *spatialFrame = spatial ? [spatial encodeColor:taaColor depth:nil motion:nil parameters:p
        commandBuffer:buffer error:&error] : nil;
    [[maybe_unused]] id<MTLBuffer> spatialPixels = spatialFrame ? probeReadback(buffer,spatialFrame.rendered) : nil;
    record(@{@"event": spatialFrame ? @"spatialSceneProbeEncoded" : @"spatialSceneProbeFailed",
        @"input": texture(taaColor), @"output": texture(spatialFrame.rendered), @"error": spatialFrame ? @"" : (error.description ?: @"unknown"),
        @"limitation": @"HDR processing of post-TAA scene color; output not displayed; color interpretation needs validation."});
    // Keep the backend and result alive until GPU completion. Never substitute
    // this experimental output into BG3's display or tone-mapping path.
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        (void)completed;
        record(@{@"event": @"sceneProbeCompleted", @"status": @(completed.status), @"error": completed.error.description ?: @"",
                 @"output": texture(frame.rendered), @"backend": NSStringFromClass(scaler.class),
                 @"statistics": completed.status == MTLCommandBufferStatusCompleted ? probeStatistics(temporalPixels,frame.rendered) : @{}});
        if (spatialFrame) record(@{@"event": @"spatialSceneProbeCompleted", @"status": @(completed.status),
            @"error": completed.error.description ?: @"", @"backend": NSStringFromClass(spatial.class),
            @"output": texture(spatialFrame.rendered),
            @"statistics": completed.status == MTLCommandBufferStatusCompleted ? probeStatistics(spatialPixels,spatialFrame.rendered) : @{}});
    }];
    record(@{@"event": @"sceneProbeEncoded", @"output": texture(frame.rendered), @"jitter": @[@(p.jitterX),@(p.jitterY)],
             @"limitation": @"One reset frame; output is not displayed. Jitter sign and temporal image quality still require validation."});
}
static void captureFrameComposition(id encoder, const CompositionDraw &call) {
    if(encodingFrameGeneration) return;
    id<MTLCommandBuffer> buffer=encoderBuffer(encoder);
    if(!frameGeneration(buffer) && !frameInterpolator && !framePresenter) return;
    NSDictionary *state=pipelineDescription(encoder);
    if(!compositionShader(state[@"fragment"])) return;
    // Only BG3's own CombineUI or CombineUI_HDR reaches here, never the worker's copy draws.
    if(!frameGeneration(buffer)) { releaseFrameGeneration(); return; }
    NSDictionary *textures=boundTextures(encoder);
    id<MTLTexture> scene=textures[@"0"],ui=textures[@"1"],target=encoderTarget(encoder);
    NSDictionary *frames=objc_getAssociatedObject(buffer,&temporalFrameKey);
    NSDictionary *inputs=scene ? frames[[NSValue valueWithPointer:(__bridge const void *)scene]] : nil;
    // Never invent motion or attach an inventory camera by size. Menus, loading
    // screens, and any frame without TAA depth, motion and camera are presented
    // unpaired; pairing resumes with the next one that has them. The Video menu
    // holds Anti-Aliasing at TAA while Frame Generation is on.
    if(!inputs) {
#ifndef BG3MFX_NO_TRACE
        // With BG3MFX_TRACE_TEMPORAL_CHAIN, show which pass lost the scene.
        NSMutableArray *associated=[NSMutableArray array];
        for(NSDictionary *frame in frames.allValues) [associated addObject:texture(frame[@"taaColor"])];
        record(@{@"event":@"frameGenerationNoScene",@"scene":texture(scene),@"mode":@(encoderScalingMode(encoder)),
            @"associated":associated,@"passes":objc_getAssociatedObject(buffer,&temporalPassHistoryKey) ?: @[]});
#endif
        return;
    }
    id pipeline=encoderPipeline(encoder);
    NSUInteger size=[objc_getAssociatedObject(pipeline,&compositorSizeKey) unsignedIntegerValue];
    ConstantBinding *vertexBinding=constantSlot(encoder,StageVertex,0);
    NSData *vertexBytes=vertexBinding && vertexBinding->hasBytes ? encoderState(encoder)->bytes[@(StageVertex*EncoderSlots)] : nil;
    NSData *constants=size && size<=4096 ? constantBytes(encoder,StageFragment,0,size) : nil;
    id sampler=encoderSampler(encoder);
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder);
    // The generated frame replays this draw with the interpolated scene, which
    // MetalFX produces at the scene's size; BG3's pipeline, viewport and
    // sampling map it onto the output, so scene, UI and output sizes may differ.
    // The pipeline fixes the output format, which follows the layer's (BGRA8Unorm
    // for SDR, BGR10A2Unorm for HDR).
    NSString *mismatch=!inputs[@"depth"] || !inputs[@"motion"] ? @"the scene has no depth or motion" :
        !pipeline || !constants || !sampler || !s ? @"its pipeline, constants or sampler were not captured" :
        !vertexBinding || (!vertexBinding->buffer && !vertexBytes) ? @"its vertices were not captured" :
        !ui || !target ? @"its UI or output texture was not captured" :
        scene.pixelFormat!=MTLPixelFormatRGB10A2Unorm ? @"unsupported scene format" : nil;
    if(mismatch) {
        declineFrameGeneration([NSString stringWithFormat:@"BG3's final scene/UI composition does not match the supported frame generation path: %@ "
            "(%@; scene %lux%lu format %lu, UI %lux%lu format %lu, output %lux%lu format %lu).",mismatch,state[@"fragment"],
            (unsigned long)scene.width,(unsigned long)scene.height,(unsigned long)scene.pixelFormat,(unsigned long)ui.width,(unsigned long)ui.height,
            (unsigned long)ui.pixelFormat,(unsigned long)target.width,(unsigned long)target.height,(unsigned long)target.pixelFormat]);return;
    }
    CompositionDraw draw=call; draw.indexBuffer=nil;
    NSMutableDictionary *request=[@{@"scene":scene,@"ui":ui,@"target":target,@"inputs":inputs,@"pipeline":pipeline,
        @"vertexOffset":@(vertexBinding->offset),@"constants":constants,@"sampler":sampler,
        @"draw":[NSData dataWithBytes:&draw length:sizeof(draw)]} mutableCopy];
    if(vertexBinding->buffer) request[@"vertices"]=vertexBinding->buffer; else request[@"vertexBytes"]=vertexBytes;
    if(call.indexBuffer) request[@"indexBuffer"]=call.indexBuffer;
    if(s->hasViewport) request[@"viewport"]=[NSData dataWithBytes:&s->viewport length:sizeof(s->viewport)];
    if(s->hasScissor) request[@"scissor"]=[NSData dataWithBytes:&s->scissor length:sizeof(s->scissor)];
    objc_setAssociatedObject(encoder,&frameCompositionKey,request,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    noteAssociation(encoder,AssocComposition);
}
static void bindViewport(__unsafe_unretained id self, SEL cmd, MTLViewport v) {
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(self);
    ((void(*)(id,SEL,MTLViewport))original(self,cmd))(self,cmd,v);
    if (s) { s->viewport=v; s->hasViewport=true; }
}
static void bindScissor(__unsafe_unretained id self, SEL cmd, MTLScissorRect r) {
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(self);
    ((void(*)(id,SEL,MTLScissorRect))original(self,cmd))(self,cmd,r);
    if (s) { s->scissor=r; s->hasScissor=true; }
}
static void sampler(__unsafe_unretained id self, SEL cmd, __unsafe_unretained id state, NSUInteger index) {
    ((void(*)(id,SEL,id,NSUInteger))original(self,cmd))(self,cmd,state,index);
    if(index==0) if (__unsafe_unretained BG3MFXEncoderState *s=encoderState(self)) s->sampler0=state;
}
static void samplers(__unsafe_unretained id self, SEL cmd, id<MTLSamplerState> const *states, NSRange range) {
    ((void(*)(id,SEL,id<MTLSamplerState> const *,NSRange))original(self,cmd))(self,cmd,states,range);
    if(range.location==0 && range.length) if (__unsafe_unretained BG3MFXEncoderState *s=encoderState(self)) s->sampler0=states[0];
}
// Draws with unrecognized pipelines skip all inspection (diagnostics excepted).
// Their only effect on the integration, invalidating a scene association for
// the encoder's color target, is applied once in endEncoder.
static bool fastDraw(__unsafe_unretained id encoder) {
    if (diagnostics) return false;
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder);
    if (s && s->kind!=PipelineOther) { s->lastDrawOther=false; return false; }
    if (s) s->lastDrawOther=true;
    return true;
}
static void drawInputs(id encoder, const CompositionDraw &call) {
    captureFrameComposition(encoder,call);
    if (!traceConstants || !temporalInputsNeeded(encoder)) return;
    NSDictionary *state = pipelineDescription(encoder);
    NSString *fragment = state[@"fragment"] ?: @"";
    int mode = encoderScalingMode(encoder);
    id<MTLCommandBuffer> encoderCommands = encoderBuffer(encoder);
    if (metalFXEnabled && sceneTracked(mode,encoderCommands) && ![fragment isEqualToString:@"PPTAA_PS"]) {
        id<MTLCommandBuffer> buffer = encoderCommands;
        NSDictionary *sceneFrames = objc_getAssociatedObject(buffer,&temporalFrameKey);
        id<MTLTexture> target = encoderTarget(encoder);
        bool tonemap = [fragment isEqualToString:@"FSR_Tonemap"];
        if ((sceneFrames.count || (mode == 2 && tonemap)) && target) {
            id<MTLTexture> source = boundTextures(encoder)[@"0"];
            NSDictionary *inputFrame = source ? sceneFrames[[NSValue valueWithPointer:(__bridge const void *)source]] : nil;
            NSMutableDictionary *next = [@{@"target":target} mutableCopy];
            if (temporalColorPass(fragment))
                labRecord(@{@"event":inputFrame ? @"sceneChainPass" : @"sceneChainMissing",@"pipeline":fragment ?: @"",
                    @"source":texture(source),@"target":texture(target),@"frames":@(sceneFrames.count)});
            if (inputFrame && source != target && source.width == target.width && source.height == target.height &&
                ((temporalColorPass(fragment) && source.pixelFormat == MTLPixelFormatRG11B10Float && target.pixelFormat == MTLPixelFormatRG11B10Float) ||
                 (frameGeneration(buffer) && [fragment isEqualToString:@"PPToneMap_LUT"]))) {
                next[@"frame"] = inputFrame; next[@"source"] = source; next[@"pipeline"] = fragment;
                if (tonemap) next[@"tonemap"] = @YES;
            }
            // Spatial needs only the color image. With SMAA or no anti-aliasing
            // there is no TAA pass to seed the chain, but FSR_Tonemap's input is
            // still the linear HDR scene color at render size that MetalFX scales.
            if (!next[@"frame"] && mode == 2 && tonemap && source && source != target &&
                source.width == target.width && source.height == target.height &&
                source.pixelFormat == MTLPixelFormatRG11B10Float && target.pixelFormat == MTLPixelFormatRG11B10Float) {
                next[@"frame"] = @{@"color":source,@"taaColor":source}; next[@"source"] = source;
                next[@"pipeline"] = fragment; next[@"tonemap"] = @YES;
            }
            // In-place scene passes (grading with bloom off, UI model VFX) draw onto an
            // already tagged image; keep its tag. An unrecognized draw later in the
            // same encoder still clears it (lastDrawOther, applied in endEncoder).
            NSDictionary *targetFrame = sceneFrames[[NSValue valueWithPointer:(__bridge const void *)target]];
            if (!next[@"frame"] && targetFrame && inPlaceScenePass(fragment) &&
                (sceneOverlayShader(fragment) || target.pixelFormat == MTLPixelFormatRG11B10Float)) {
                next[@"frame"] = targetFrame; next[@"source"] = target; next[@"pipeline"] = fragment; next[@"keep"] = @YES;
            }
            objc_setAssociatedObject(encoder,&temporalPostprocessKey,next,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            noteAssociation(encoder,AssocPostprocess);
        }
    }
    if (diagnostics || [fragment isEqualToString:@"PPTAA_PS"] || [fragment isEqualToString:@"LinearizeDepth"] || [fragment isEqualToString:@"VelocityBufferCamera_PS"])
        captureSceneInputs(encoder,fragment);
    if ([fragment isEqualToString:@"PPTAA_PS"] || [fragment isEqualToString:@"LinearizeDepth"] || [fragment isEqualToString:@"VelocityBufferCamera_PS"] ||
        [fragment isEqualToString:@"VelocityBufferCamera_PS"] || [fragment containsString:@"_VEL_"]) {
        record(@{@"event": @"drawInputs", @"pipeline": state,
                 @"bindings": objc_getAssociatedObject(encoder, &bindingsKey) ?: @{},
                 @"attachments": objc_getAssociatedObject(encoder, &attachmentsKey) ?: @{}});
    }
}
static BOOL suppressTemporalTAA(id encoder) {
    if (!metalFXEnabled || temporalFailed || encoderScalingMode(encoder) != 3) return NO;
    NSDictionary *state = pipelineDescription(encoder);
    if (![state[@"fragment"] isEqualToString:@"PPTAA_PS"] || !objc_getAssociatedObject(encoder,&taaInputsKey)) return NO;
    if (!knownUpscaledTAA(encoderTarget(encoder))) return NO;
    objc_setAssociatedObject(encoder,&temporalSuppressedKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    noteAssociation(encoder,AssocSuppressed);
    record(@{@"event":@"temporalNativeTAADrawSkipped",@"pipeline":state});
    return YES;
}
static void draw(__unsafe_unretained id self, SEL cmd, MTLPrimitiveType type, NSUInteger start, NSUInteger count) {
    if (labWork(self,@"draws")) return;
    LabPokeScope poke(self);
    BG3MFXPrepassDraw trim(self,prepassState(self),setPrepassDepth,diagnostics);
    if (trim.skip) return;
    if (fastDraw(self)) { ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,start,count); return; }
    drawInputs(self,CompositionDraw{type,start,count,1,0,0,nil,0,MTLIndexTypeUInt16});
    if (suppressTemporalTAA(self)) return;
    ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,start,count);
}
static void drawInstances(__unsafe_unretained id self, SEL cmd, MTLPrimitiveType type, NSUInteger start, NSUInteger count, NSUInteger instances) {
    if (labWork(self,@"draws")) return;
    LabPokeScope poke(self);
    BG3MFXPrepassDraw trim(self,prepassState(self),setPrepassDepth,diagnostics);
    if (trim.skip) return;
    if (fastDraw(self)) { ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,start,count,instances); return; }
    drawInputs(self,CompositionDraw{type,start,count,instances,0,0,nil,0,MTLIndexTypeUInt16});
    if (suppressTemporalTAA(self)) return;
    ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,start,count,instances);
}
static void drawBaseInstance(__unsafe_unretained id self, SEL cmd, MTLPrimitiveType type, NSUInteger start, NSUInteger count, NSUInteger instances, NSUInteger base) {
    if (labWork(self,@"draws")) return;
    LabPokeScope poke(self);
    BG3MFXPrepassDraw trim(self,prepassState(self),setPrepassDepth,diagnostics);
    if (trim.skip) return;
    if (fastDraw(self)) { ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,start,count,instances,base); return; }
    drawInputs(self,CompositionDraw{type,start,count,instances,base,0,nil,0,MTLIndexTypeUInt16});
    if (suppressTemporalTAA(self)) return;
    ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,start,count,instances,base);
}
static void drawIndexed(__unsafe_unretained id self, SEL cmd, MTLPrimitiveType type, NSUInteger count, MTLIndexType indexType, __unsafe_unretained id<MTLBuffer> buffer, NSUInteger offset) {
    if (labWork(self,@"draws")) return;
    LabPokeScope poke(self);
    BG3MFXPrepassDraw trim(self,prepassState(self),setPrepassDepth,diagnostics);
    if (trim.skip) return;
    if (fastDraw(self)) { ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id,NSUInteger))original(self,cmd))(self,cmd,type,count,indexType,buffer,offset); return; }
    drawInputs(self,CompositionDraw{type,0,count,1,0,0,buffer,offset,indexType});
#ifndef BG3MFX_NO_TRACE
    captureWaterfall(self,@{@"indexCount":@(count),@"indexType":@(indexType),@"indexBuffer":buffer,@"indexOffset":@(offset),@"instances":@1,@"baseVertex":@0,@"baseInstance":@0});
#endif
    if (suppressTemporalTAA(self)) return;
    ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id,NSUInteger))original(self,cmd))(self,cmd,type,count,indexType,buffer,offset);
}
static void drawIndexedInstances(__unsafe_unretained id self, SEL cmd, MTLPrimitiveType type, NSUInteger count, MTLIndexType indexType, __unsafe_unretained id<MTLBuffer> buffer, NSUInteger offset, NSUInteger instances) {
    if (labWork(self,@"draws")) return;
    LabPokeScope poke(self);
    BG3MFXPrepassDraw trim(self,prepassState(self),setPrepassDepth,diagnostics);
    if (trim.skip) return;
    if (fastDraw(self)) { ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,count,indexType,buffer,offset,instances); return; }
    drawInputs(self,CompositionDraw{type,0,count,instances,0,0,buffer,offset,indexType});
#ifndef BG3MFX_NO_TRACE
    captureWaterfall(self,@{@"indexCount":@(count),@"indexType":@(indexType),@"indexBuffer":buffer,@"indexOffset":@(offset),@"instances":@(instances),@"baseVertex":@0,@"baseInstance":@0});
#endif
    if (suppressTemporalTAA(self)) return;
    ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,count,indexType,buffer,offset,instances);
}
static void drawIndexedBase(__unsafe_unretained id self, SEL cmd, MTLPrimitiveType type, NSUInteger count, MTLIndexType indexType, __unsafe_unretained id<MTLBuffer> buffer, NSUInteger offset, NSUInteger instances, NSInteger baseVertex, NSUInteger baseInstance) {
    if (labWork(self,@"draws")) return;
    LabPokeScope poke(self);
    BG3MFXPrepassDraw trim(self,prepassState(self),setPrepassDepth,diagnostics);
    if (trim.skip) return;
    if (fastDraw(self)) { ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id,NSUInteger,NSUInteger,NSInteger,NSUInteger))original(self,cmd))(self,cmd,type,count,indexType,buffer,offset,instances,baseVertex,baseInstance); return; }
    drawInputs(self,CompositionDraw{type,0,count,instances,baseInstance,baseVertex,buffer,offset,indexType});
#ifndef BG3MFX_NO_TRACE
    captureWaterfall(self,@{@"indexCount":@(count),@"indexType":@(indexType),@"indexBuffer":buffer,@"indexOffset":@(offset),@"instances":@(instances),@"baseVertex":@(baseVertex),@"baseInstance":@(baseInstance)});
#endif
    if (suppressTemporalTAA(self)) return;
    ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id,NSUInteger,NSUInteger,NSInteger,NSUInteger))original(self,cmd))(self,cmd,type,count,indexType,buffer,offset,instances,baseVertex,baseInstance);
}
// Native compute with Frame Generation: carry the scene's association from
// FSR's input through its upscale and RCAS sharpening, as for the MetalFX
// outputs, and through CAS, the FidelityFX sharpening BG3 applies after tone
// mapping when no upscaler runs.
static char nativeFSRKey;
static void forwardNativeCompute(id encoder, NSString *name, NSDictionary *textures, id<MTLCommandBuffer> buffer, int mode) {
    NSMutableDictionary *frames = objc_getAssociatedObject(buffer,&temporalFrameKey);
    if ([name isEqualToString:@"CAS"]) {
        id<MTLTexture> source = textures[@"0"], target = textures[@"1"];
        NSDictionary *frame = source ? frames[[NSValue valueWithPointer:(__bridge const void *)source]] : nil;
        if (frame && target && target != source && target.width == source.width && target.height == source.height)
            frames[[NSValue valueWithPointer:(__bridge const void *)target]] = frame;
    } else if (mode != 1) {
        // Spatial and Temporal replace FSR and RCAS and attach their own output.
    } else if ([name isEqualToString:@"FSR"]) {
        id<MTLTexture> source = textures[@"0"], scaled = textures[@"1"];
        NSDictionary *frame = source ? frames[[NSValue valueWithPointer:(__bridge const void *)source]] : nil;
        objc_setAssociatedObject(encoder,&nativeFSRKey,frame && scaled ? @{@"frame":frame,@"scaled":scaled} : nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if ([name isEqualToString:@"FSR_RCAS"]) {
        NSDictionary *pending = objc_getAssociatedObject(encoder,&nativeFSRKey);
        objc_setAssociatedObject(encoder,&nativeFSRKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        id<MTLTexture> destination = textures[@"2"];
        if (pending && pending[@"scaled"] == textures[@"0"] && destination)
            frames[[NSValue valueWithPointer:(__bridge const void *)destination]] = pending[@"frame"];
    }
}
static void dispatchIndirect(id self, SEL cmd, id<MTLBuffer> buffer, NSUInteger offset, MTLSize threads) {
    if (labWork(self,@"dispatches")) return;
    std::vector<LabPoke> poked = labPoke(self);
    ((void(*)(id,SEL,id,NSUInteger,MTLSize))original(self,cmd))(self,cmd,buffer,offset,threads);
    labUnpoke(self,poked);
}
static void dispatchNative(id self, SEL cmd, MTLSize grid, MTLSize threads);
static void dispatch(id self, SEL cmd, MTLSize grid, MTLSize threads) {
    if (!labEnabled) { dispatchNative(self,cmd,grid,threads); return; }
    if (labWork(self,@"dispatches",[NSString stringWithFormat:@"%@ %lux%lux%lu / %lux%lux%lu",
            cmd == @selector(dispatchThreads:threadsPerThreadgroup:) ? @"threads" : @"groups",
            (unsigned long)grid.width,(unsigned long)grid.height,(unsigned long)grid.depth,
            (unsigned long)threads.width,(unsigned long)threads.height,(unsigned long)threads.depth])) return;
    std::vector<LabPoke> poked = labPoke(self);
    dispatchNative(self,cmd,grid,threads);
    labUnpoke(self,poked);
}
static void dispatchNative(id self, SEL cmd, MTLSize grid, MTLSize threads) {
    BOOL suppressNative = NO;
    NSDictionary *state = pipelineDescription(self);
    NSString *pipelineName = state[@"compute"];
    NSDictionary *textures = boundTextures(self);
    NSDictionary *pending = objc_getAssociatedObject(self,&fsrInputsKey);
    id<MTLCommandBuffer> buffer = encoderBuffer(self);
    int mode = pending ? [pending[@"mode"] intValue] : encoderScalingMode(self);
    BOOL temporal = mode == 3;
    BOOL selectedMetalFX = (mode == 2 && metalFXEnabled) || (temporal && metalFXEnabled);
    if (selectedMetalFX) {
        if (temporal ? temporalFailed : spatialFailed) goto native;
        if ([pipelineName isEqualToString:@"FSR"]) {
            id<MTLTexture> source = textures[@"0"], scaled = textures[@"1"];
            if (pending || !source || !scaled || !buffer) {
                if (temporal) failTemporal(@"Unexpected FSR scaling resources or dispatch sequence.");
                else failSpatial(@"Unexpected FSR scaling resources or dispatch sequence.");
                return;
            }
            NSDictionary *frames = objc_getAssociatedObject(buffer,&temporalFrameKey);
            NSDictionary *frame = frames[[NSValue valueWithPointer:(__bridge const void *)source]];
            id<MTLTexture> spatialColor = frame[@"color"];
            // A split-screen view is upscaled on its own, into its share of the output.
            NSArray *view = frame[@"view"];
            MTLRegion outputView = view ? BG3MFXScaleViewRegion(view,source.width,source.height,scaled.width,scaled.height)
                                        : MTLRegionMake2D(0,0,scaled.width,scaled.height);
            NSUInteger viewWidth = view ? [view[2] unsignedIntegerValue] : spatialColor.width;
            NSUInteger viewHeight = view ? [view[3] unsignedIntegerValue] : spatialColor.height;
            if (temporal) {
                if (!frame || source != frame[@"taaColor"]) labRecord(@{@"event":@"fsrSceneLookup",@"source":texture(source),
                    @"frames":@(frames.count),@"found":@(frame != nil)});
                if (!frame || source != frame[@"taaColor"] || scaled.width < source.width || scaled.height < source.height) {
#ifndef BG3MFX_NO_TRACE
                    NSMutableArray *targets = [NSMutableArray array];
                    for (NSDictionary *candidate in frames.allValues) [targets addObject:texture(candidate[@"taaColor"])];
                    record(@{@"event":@"nativeMenuTemporalMismatch",@"source":texture(source),@"capturedTargets":targets,
                        @"passes":objc_getAssociatedObject(buffer,&temporalPassHistoryKey) ?: @[]});
#endif
                    fallBackToNative(self,YES,[NSString stringWithFormat:@"The native upscaling stage did not match the captured temporal scene inputs (%@).", !frame ? (objc_getAssociatedObject(buffer,&sceneCaptureFailureKey) ?: @"no matching scene color") : source != frame[@"taaColor"] ? @"different scene color target" : @"invalid output dimensions"]);
                    goto native;
                }
                if (!temporalSizeSettled(scalerKey(buffer.device,viewWidth,viewHeight,outputView.size.width,outputView.size.height))) {
                    fallBackToNative(self,YES,@"The output size is changing; waiting for it to settle before creating a Temporal scaler.");
                    goto native;
                }
            } else if (!spatialColor || spatialColor.width != source.width || spatialColor.height != source.height ||
                       spatialColor.pixelFormat != MTLPixelFormatRG11B10Float) {
                fallBackToNative(self,NO,@"Could not match FSR input to BG3's linear HDR scene color.");
                goto native;
            } else if (!temporal && !spatialSizeSettled(scalerKey(buffer.device,spatialColor.width,spatialColor.height,scaled.width,scaled.height))) {
                fallBackToNative(self,NO,@"The output size is changing; waiting for it to settle before creating a Spatial scaler.");
                goto native;
            }
            NSMutableDictionary *request = [@{@"input":temporal ? source : spatialColor,@"encodedInput":source,
                @"scaled":scaled,@"mode":@(mode)} mutableCopy];
            // Absent when Spatial was seeded at FSR_Tonemap without a TAA pass.
            if (frame[@"nativeTAA"]) request[@"nativeTAA"] = frame[@"nativeTAA"];
            if (view) {
                request[@"view"] = view;
                request[@"outputView"] = @[@(outputView.origin.x),@(outputView.origin.y),@(outputView.size.width),@(outputView.size.height)];
            }
            objc_setAssociatedObject(self,&fsrInputsKey,request,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            noteAssociation(self,AssocFSRInputs);
            suppressNative = YES;
        } else if ([pipelineName isEqualToString:@"FSR_RCAS"]) {
            // The fallback frame keeps BG3's own sharpening pass too.
            if (!pending && objc_getAssociatedObject(self,&nativeFallbackKey)) goto native;
            if (pending && !pending[@"destination"] && pending[@"scaled"] == textures[@"0"] && textures[@"2"]) {
                NSMutableDictionary *complete = [pending mutableCopy]; complete[@"destination"] = textures[@"2"];
                // Everything needed to replay this sharpening on the MetalFX result.
                __unsafe_unretained BG3MFXEncoderState *s = encoderState(self);
                ConstantBinding *constants = constantSlot(self,StageCompute,0);
                NSData *bytes = constants && constants->hasBytes ? s->bytes[@(StageCompute*EncoderSlots)] : nil;
                if (s && s->pipeline && (bytes || (constants && constants->buffer))) {
                    NSMutableDictionary *rcas = [@{@"pipeline":s->pipeline,@"grid":@[@(grid.width),@(grid.height),@(grid.depth)],
                        @"threads":@[@(threads.width),@(threads.height),@(threads.depth)],
                        @"threadgroups":@(cmd == @selector(dispatchThreadgroups:threadsPerThreadgroup:))} mutableCopy];
                    if (textures[@"1"]) rcas[@"hairMask"] = textures[@"1"];
                    if (bytes) rcas[@"constants"] = bytes;
                    else { rcas[@"constantsBuffer"] = constants->buffer; rcas[@"constantsOffset"] = @(constants->offset); }
                    complete[@"rcas"] = rcas;
                }
                objc_setAssociatedObject(self,&fsrInputsKey,complete,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                noteAssociation(self,AssocFSRInputs);
                suppressNative = YES;
            } else {
                if (temporal) failTemporal(@"Unexpected native FSR sharpening resources or dispatch sequence.");
                else failSpatial(@"Unexpected FSR sharpening resources or dispatch sequence.");
                return;
            }
        } else if (pending) {
            if (temporal) failTemporal(@"An unexpected compute dispatch interrupted the MetalFX replacement.");
            else failSpatial(@"An unexpected compute dispatch interrupted the MetalFX replacement.");
            return;
        }
    }
native:
#ifndef BG3MFX_NO_TRACE
    if (diagnostics) noteClusterDispatch(self,pipelineName);
#endif
    if (metalFXEnabled && buffer && frameGeneration(buffer)) forwardNativeCompute(self,pipelineName,textures,buffer,mode);
    if (traceConstants) {
        NSDictionary *state = pipelineDescription(self);
        NSString *name = state[@"compute"] ?: @"";
        if ([name isEqualToString:@"FSR"] || [name isEqualToString:@"FSR_RCAS"] ||
            [name isEqualToString:@"BG3MFXDispatchSmoke"]) {
            record(@{@"event": @"dispatchInputs", @"method": NSStringFromSelector(cmd), @"pipeline": state,
                @"grid": @[@(grid.width),@(grid.height),@(grid.depth)],
                @"threadsPerGroup": @[@(threads.width),@(threads.height),@(threads.depth)],
                @"bindings": objc_getAssociatedObject(self, &bindingsKey) ?: @{}});
        }
    }
    if (suppressNative) {
        record(@{@"event":temporal ? @"temporalNativeDispatchSkipped" : @"spatialNativeDispatchSkipped",
            @"pipeline":pipelineDescription(self),
            @"method":NSStringFromSelector(cmd)});
        return;
    }
    ((void(*)(id,SEL,MTLSize,MTLSize))original(self,cmd))(self,cmd,grid,threads);
}
// Encoder classes whose methods are already hooked. hook() would find each one
// installed, but only after taking the global lock about 25 times per encoder.
// Classes are never deallocated, so their addresses are stable keys.
static std::atomic<uintptr_t> instrumentedEncoderClasses[16];
static bool encoderClassInstrumented(Class cls) {
    uintptr_t key = (uintptr_t)(__bridge void *)cls;
    for (auto &known : instrumentedEncoderClasses) {
        uintptr_t value = known.load(std::memory_order_acquire);
        if (value == key) return true;
        if (!value) return false;
    }
    return false;
}
static void markEncoderClassInstrumented(Class cls) {
    uintptr_t key = (uintptr_t)(__bridge void *)cls;
    for (auto &known : instrumentedEncoderClasses) {
        uintptr_t empty = 0;
        if (known.load(std::memory_order_acquire) == key ||
            known.compare_exchange_strong(empty, key, std::memory_order_acq_rel)) return;
    }
}
static void instrumentEncoder(id encoder) {
    // Drivers recycle encoder objects: start each one with fresh state, and
    // drop whatever the previous user of this object left. Its state records
    // which keys were set; an object never seen before is cleared in full.
    uint16_t stale = AssocAll;
    if (encoder) {
        __unsafe_unretained BG3MFXEncoderState *previous = objc_getAssociatedObject(encoder,&encoderStateKey);
        if (previous) stale = previous->associations;
    }
    if (stale & AssocFSRInputs) objc_setAssociatedObject(encoder, &fsrInputsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (stale & AssocComposition) objc_setAssociatedObject(encoder,&frameCompositionKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (encoder) {
        BG3MFXEncoderState *state = [BG3MFXEncoderState new];
        unsigned generation = encoderGeneration.fetch_add(1, std::memory_order_acq_rel) + 1;
        objc_setAssociatedObject(encoder,&encoderStateKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        hookCache.encoder = (__bridge const void *)encoder; hookCache.state = (__bridge void *)state;
        hookCache.encoderGeneration = generation;
    }
    if (stale & AssocBindings) objc_setAssociatedObject(encoder, &bindingsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (stale & AssocAttachments) objc_setAssociatedObject(encoder, &attachmentsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (stale & AssocTAAInputs) objc_setAssociatedObject(encoder, &taaInputsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (stale & AssocPostprocess) objc_setAssociatedObject(encoder, &temporalPostprocessKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (stale & AssocSuppressed) objc_setAssociatedObject(encoder, &temporalSuppressedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!encoder || encoderClassInstrumented(object_getClass(encoder))) return;
    if (traceConstants) {
        hook(encoder,"setFragmentBuffer:offset:atIndex:",(IMP)bindBuffer);
        hook(encoder,"setVertexBuffer:offset:atIndex:",(IMP)bindBuffer);
        hook(encoder,"setFragmentBuffers:offsets:withRange:",(IMP)bindBuffers);
        hook(encoder,"setVertexBuffers:offsets:withRange:",(IMP)bindBuffers);
        hook(encoder,"setFragmentBufferOffset:atIndex:",(IMP)bufferOffset);
        hook(encoder,"setVertexBufferOffset:atIndex:",(IMP)bufferOffset);
        hook(encoder,"setFragmentBytes:length:atIndex:",(IMP)bindBytes);
        hook(encoder,"setVertexBytes:length:atIndex:",(IMP)bindBytes);
        hook(encoder,"drawPrimitives:vertexStart:vertexCount:",(IMP)draw);
        hook(encoder,"drawPrimitives:vertexStart:vertexCount:instanceCount:",(IMP)drawInstances);
        hook(encoder,"drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:",(IMP)drawBaseInstance);
        hook(encoder,"drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:",(IMP)drawIndexed);
        hook(encoder,"drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:",(IMP)drawIndexedInstances);
        hook(encoder,"drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:",(IMP)drawIndexedBase);
        if (prepassTrim) hook(encoder,"setDepthStencilState:",(IMP)setDepthStencilHook);
    }
    if (diagnostics) hook(encoder,"setLabel:",(IMP)label);
    if (diagnostics) hook(encoder,"pushDebugGroup:",(IMP)group);
    hook(encoder,"setViewport:",(IMP)bindViewport);
    hook(encoder,"setScissorRect:",(IMP)bindScissor);
    hook(encoder,"setFragmentSamplerState:atIndex:",(IMP)sampler);
    hook(encoder,"setFragmentSamplerStates:withRange:",(IMP)samplers);
    hook(encoder,"setFragmentTexture:atIndex:",(IMP)bindTexture);
    hook(encoder,"setTexture:atIndex:",(IMP)bindTexture);
    hook(encoder,"setFragmentTextures:withRange:",(IMP)bindTextures);
    hook(encoder,"setTextures:withRange:",(IMP)bindTextures);
    hook(encoder,"endEncoding",(IMP)endEncoder);
    hook(encoder,"setRenderPipelineState:",(IMP)pipeline);
    hook(encoder,"setComputePipelineState:",(IMP)pipeline);
    if (traceConstants) {
        hook(encoder,"dispatchThreads:threadsPerThreadgroup:",(IMP)dispatch);
        hook(encoder,"dispatchThreadgroups:threadsPerThreadgroup:",(IMP)dispatch);
    }
    if (labEnabled) hook(encoder,"dispatchThreadgroupsWithIndirectBuffer:indirectBufferOffset:threadsPerThreadgroup:",(IMP)dispatchIndirect);
    if (labEnabled || metalFXEnabled) {
        // Compute constant buffers: lab watch records and poke rules, BG3's
        // RCAS constants, replayed to sharpen MetalFX output (Sharpening.h),
        // and in diagnostics the cluster guard's slots (clusterGuard needs
        // metalFXEnabled).
        hook(encoder,"setBuffer:offset:atIndex:",(IMP)bindBuffer);
        hook(encoder,"setBuffers:offsets:withRange:",(IMP)bindBuffers);
        hook(encoder,"setBufferOffset:atIndex:",(IMP)bufferOffset);
        hook(encoder,"setBytes:length:atIndex:",(IMP)bindBytes);
    }
    markEncoderClassInstrumented(object_getClass(encoder));
}
static id computeEncoderType(id self, SEL cmd, MTLDispatchType type);
static std::map<Class, IMP> &priorComputeMethods() { static auto *value = new std::map<Class, IMP>; return *value; }
static void refreshComputeHook(id buffer) {
    if (!traceConstants) return;
    std::lock_guard<std::recursive_mutex> lock(guard());
    Class cls = object_getClass(buffer);
    SEL selector = sel_registerName("computeCommandEncoderWithDispatchType:");
    auto found = originals().find({cls,selector});
    Method method = class_getInstanceMethod(cls,selector);
    if (found == originals().end() || !method || method_getImplementation(method) == (IMP)computeEncoderType) return;
    // Preserve later instrumentation as the outer original. If it retained our
    // old wrapper, nested entry will use the earlier original to avoid a cycle.
    priorComputeMethods().emplace(cls,found->second);
    found->second = method_getImplementation(method);
    originalsGeneration.fetch_add(1, std::memory_order_release);
    class_replaceMethod(cls,selector,(IMP)computeEncoderType,method_getTypeEncoding(method));
    record(@{@"event": @"computeHookRefreshed", @"class": NSStringFromClass(cls)});
}
static id renderEncoder(id self, SEL cmd, MTLRenderPassDescriptor *desc) {
    refreshComputeHook(self);
    if (diagnostics) {
    [[maybe_unused]] BOOL computeRegistered;
    { std::lock_guard<std::recursive_mutex> lock(guard());
      computeRegistered = originals().count({object_getClass(self), sel_registerName("computeCommandEncoderWithDispatchType:")}); }
    Method computeMethod = class_getInstanceMethod(object_getClass(self),sel_registerName("computeCommandEncoderWithDispatchType:"));
    Dl_info computeImage = {};
    if (computeMethod) dladdr((const void *)method_getImplementation(computeMethod), &computeImage);
    record(@{@"event": @"commandBufferHooks", @"class": NSStringFromClass(object_getClass(self)),
        @"computeImplementationImage": computeImage.dli_fname ? [NSString stringWithUTF8String:computeImage.dli_fname] : @"",
        @"computeHookRegistered": @(computeRegistered),
        @"computeHookActive": @(computeMethod && method_getImplementation(computeMethod) == (IMP)computeEncoderType)});
    }
    NSUInteger samples = labEnabled ? labProfileSamples([(id<MTLCommandBuffer>)self device]) : NSNotFound;
    if (samples != NSNotFound) {
        MTLRenderPassDescriptor *profiled = [desc copy];
        MTLRenderPassSampleBufferAttachmentDescriptor *attachment = profiled.sampleBufferAttachments[0];
        attachment.sampleBuffer = labCounters;
        attachment.startOfVertexSampleIndex = samples; attachment.endOfVertexSampleIndex = MTLCounterDontSample;
        attachment.startOfFragmentSampleIndex = MTLCounterDontSample; attachment.endOfFragmentSampleIndex = samples + 1;
        desc = profiled;
    }
    id encoder = ((id(*)(id,SEL,id))original(self,cmd))(self,cmd,desc);
    instrumentEncoder(encoder);
    if (clusterGuard) BG3MFXBindClusterStandIns(encoder,NO);
    setEncoderMode(encoder, objc_getAssociatedObject(self, &bufferScalingModeKey));
    flushRedundantCounts();
    if (prepassTrim && encoder) if (__unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder)) {
        s->prepass.role=BG3MFXPrepassRole(desc);
        // Diagnostics: report the previous frame's counts at each trimmed prepass.
        if (diagnostics && s->prepass.role==RolePrepass) {
            [[maybe_unused]] auto counts=BG3MFXDrainPrepassCounts();
            record(@{@"event":@"prepassTrim",@"frame":@(frames),@"skipped":@(counts.skipped),@"swapped":@(counts.swapped)});
        }
    }
    if (diagnostics) {
    NSMutableArray *colors = [NSMutableArray array];
    for (NSUInteger i=0; i<8; ++i) if (desc.colorAttachments[i].texture)
        [colors addObject:texture(desc.colorAttachments[i].texture)];
    NSDictionary *attachments = @{@"color": colors, @"depth": texture(desc.depthAttachment.texture)};
    if (encoder) objc_setAssociatedObject(encoder, &attachmentsKey, attachments, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    noteAssociation(encoder,AssocAttachments);
        record(@{@"event": @"renderPass", @"color": colors, @"depth": attachments[@"depth"]});
    }
    if ((sceneProbe || metalFXEnabled || labEnabled) && encoder) {
        if (__unsafe_unretained BG3MFXEncoderState *state=encoderState(encoder)) { state->buffer=self; state->colorTarget=desc.colorAttachments[0].texture; }
    }
    if (labEnabled && encoder) labBeginEncoder(encoder,@"render",desc,self);
    if (samples != NSNotFound) if (__unsafe_unretained BG3MFXEncoderState *s = encoderState(encoder)) s->labRecord[@"samples"] = @(samples);
    return encoder;
}
// BG3 copies scene color between post-processing passes with blits in split
// screen (bloom's result into colour grading's input). Follow the scene through
// such copies as through the recognized color passes.
static char blitBufferKey;
static void followSceneCopy(id encoder, id<MTLTexture> source, id<MTLTexture> destination) {
    if (!metalFXEnabled || !source || !destination || source == destination) return;
    if (labRecording && source.width >= 256 && source.height >= 256) {
        static std::atomic<unsigned> copies{0};
        if (copies.fetch_add(1) < 3000) labRecord(@{@"event":@"textureCopy",@"source":texture(source),@"destination":texture(destination)});
    }
    id<MTLCommandBuffer> buffer = objc_getAssociatedObject(encoder,&blitBufferKey);
    NSMutableDictionary *frames = buffer ? objc_getAssociatedObject(buffer,&temporalFrameKey) : nil;
    NSDictionary *frame = frames[[NSValue valueWithPointer:(__bridge const void *)source]];
    if (!frame || destination.width != source.width || destination.height != source.height || destination.pixelFormat != source.pixelFormat) return;
    NSMutableDictionary *next = [frame mutableCopy];
    next[@"taaColor"] = destination; next[@"color"] = destination;
    frames[[NSValue valueWithPointer:(__bridge const void *)destination]] = next;
    labRecord(@{@"event":@"temporalColorCopied",@"source":texture(source),@"destination":texture(destination)});
}
static void blitRegion(__unsafe_unretained id self, SEL cmd, __unsafe_unretained id<MTLTexture> source, NSUInteger sourceSlice, NSUInteger sourceLevel,
                       MTLOrigin sourceOrigin, MTLSize sourceSize, __unsafe_unretained id<MTLTexture> destination, NSUInteger destinationSlice,
                       NSUInteger destinationLevel, MTLOrigin destinationOrigin) {
    ((void(*)(id,SEL,id,NSUInteger,NSUInteger,MTLOrigin,MTLSize,id,NSUInteger,NSUInteger,MTLOrigin))original(self,cmd))
        (self,cmd,source,sourceSlice,sourceLevel,sourceOrigin,sourceSize,destination,destinationSlice,destinationLevel,destinationOrigin);
    followSceneCopy(self,source,destination);
}
static void blitWhole(__unsafe_unretained id self, SEL cmd, __unsafe_unretained id<MTLTexture> source, __unsafe_unretained id<MTLTexture> destination) {
    ((void(*)(id,SEL,id,id))original(self,cmd))(self,cmd,source,destination);
    followSceneCopy(self,source,destination);
}
static void blitSlices(__unsafe_unretained id self, SEL cmd, __unsafe_unretained id<MTLTexture> source, NSUInteger sourceSlice, NSUInteger sourceLevel,
                       __unsafe_unretained id<MTLTexture> destination, NSUInteger destinationSlice, NSUInteger destinationLevel,
                       NSUInteger sliceCount, NSUInteger levelCount) {
    ((void(*)(id,SEL,id,NSUInteger,NSUInteger,id,NSUInteger,NSUInteger,NSUInteger,NSUInteger))original(self,cmd))
        (self,cmd,source,sourceSlice,sourceLevel,destination,destinationSlice,destinationLevel,sliceCount,levelCount);
    followSceneCopy(self,source,destination);
}
static id blitEncoder(id self, SEL cmd) {
    id encoder = ((id(*)(id,SEL))original(self,cmd))(self,cmd);
    if (encoder && metalFXEnabled) {
        objc_setAssociatedObject(encoder,&blitBufferKey,self,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        hook(encoder,"copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:",(IMP)blitRegion);
        hook(encoder,"copyFromTexture:toTexture:",(IMP)blitWhole);
        hook(encoder,"copyFromTexture:sourceSlice:sourceLevel:toTexture:destinationSlice:destinationLevel:sliceCount:levelCount:",(IMP)blitSlices);
    }
    return encoder;
}
static id blitEncoderDescriptor(id self, SEL cmd, id descriptor) {
    id encoder = ((id(*)(id,SEL,id))original(self,cmd))(self,cmd,descriptor);
    if (encoder && metalFXEnabled) {
        objc_setAssociatedObject(encoder,&blitBufferKey,self,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        hook(encoder,"copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:",(IMP)blitRegion);
        hook(encoder,"copyFromTexture:toTexture:",(IMP)blitWhole);
        hook(encoder,"copyFromTexture:sourceSlice:sourceLevel:toTexture:destinationSlice:destinationLevel:sliceCount:levelCount:",(IMP)blitSlices);
    }
    return encoder;
}
static id computeEncoder(id self, SEL cmd) {
    if (labCreatingProfiledEncoder) return ((id(*)(id,SEL))original(self,cmd))(self,cmd);
    NSUInteger samples = labEnabled ? labProfileSamples([(id<MTLCommandBuffer>)self device]) : NSNotFound;
    id encoder = samples != NSNotFound ? labProfiledComputeEncoder(self,MTLDispatchTypeSerial,samples) : ((id(*)(id,SEL))original(self,cmd))(self,cmd);
    record(@{@"event": @"computeEncoderCreated", @"method": NSStringFromSelector(cmd), @"class": NSStringFromClass([encoder class])});
    instrumentEncoder(encoder);
    if (clusterGuard) BG3MFXBindClusterStandIns(encoder,YES);
    setEncoderMode(encoder, objc_getAssociatedObject(self, &bufferScalingModeKey));
    if (metalFXEnabled || labEnabled) if (__unsafe_unretained BG3MFXEncoderState *state=encoderState(encoder)) state->buffer=self;
    if (labEnabled && encoder) labBeginEncoder(encoder,@"compute",nil,self);
    if (samples != NSNotFound) if (__unsafe_unretained BG3MFXEncoderState *s = encoderState(encoder)) s->labRecord[@"samples"] = @(samples);
    return encoder;
}
static id computeEncoderType(id self, SEL cmd, MTLDispatchType type) {
    static thread_local void *activeBuffer = nullptr;
    void *previous = activeBuffer;
    IMP forward = original(self,cmd);
    if (activeBuffer == (__bridge void *)self) {
        std::lock_guard<std::recursive_mutex> lock(guard());
        for (Class cls=object_getClass(self); cls; cls=class_getSuperclass(cls)) {
            auto found = priorComputeMethods().find(cls);
            if (found != priorComputeMethods().end()) { forward = found->second; break; }
        }
    }
    if (labCreatingProfiledEncoder) return ((id(*)(id,SEL,MTLDispatchType))forward)(self,cmd,type);
    NSUInteger samples = labEnabled ? labProfileSamples([(id<MTLCommandBuffer>)self device]) : NSNotFound;
    activeBuffer = (__bridge void *)self;
    id encoder = samples != NSNotFound ? labProfiledComputeEncoder(self,type,samples) : ((id(*)(id,SEL,MTLDispatchType))forward)(self,cmd,type);
    activeBuffer = previous;
    record(@{@"event": @"computeEncoderCreated", @"method": NSStringFromSelector(cmd), @"dispatchType": @(type), @"class": NSStringFromClass([encoder class])});
    instrumentEncoder(encoder);
    if (clusterGuard) BG3MFXBindClusterStandIns(encoder,YES);
    setEncoderMode(encoder, objc_getAssociatedObject(self, &bufferScalingModeKey));
    if (metalFXEnabled || labEnabled) if (__unsafe_unretained BG3MFXEncoderState *state=encoderState(encoder)) state->buffer=self;
    if (labEnabled && encoder) labBeginEncoder(encoder,@"compute",nil,self);
    if (samples != NSNotFound) if (__unsafe_unretained BG3MFXEncoderState *s = encoderState(encoder)) s->labRecord[@"samples"] = @(samples);
    return encoder;
}
static void countPresent(id drawable, SEL cmd) {
    (void)drawable; (void)cmd;
    if (labEnabled) labFrameBoundary();
    BG3MFXFrameLogRendered();
    std::lock_guard<std::recursive_mutex> lock(guard()); ++frames;
    if (frames == 1 || frames == 120 || frames % 3600 == 0)
        record(@{@"event": @"present", @"method": NSStringFromSelector(cmd), @"frames": @(frames), @"texture": texture([drawable texture])});
}
// While Frame Generation is active BG3 renders into stand-in drawables (see
// layerNextDrawable). BG3 schedules its present before encoding CombineUI, so
// the decision waits for commit, once the generated pair exists. The original
// present never sees a stand-in.
static BOOL deferPresent(id buffer, SEL cmd, id drawable) {
    if (![BG3MFXFramePresenter presenterForStandIn:drawable]) return NO;
    if (objc_getAssociatedObject(buffer,&deferredPresentKey)) { [drawable present]; return YES; }
    objc_setAssociatedObject(buffer,&deferredPresentKey,@{@"method":NSStringFromSelector(cmd),@"drawable":drawable},
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}
// With Frame Generation off, BG3 presents real drawables itself. Latency is
// measured from the buffer's commit, as for Frame Generation's stand-ins.
static char nativePresentKey;
static void logNativePresent(id buffer, id drawable) {
    if (!BG3MFXFrameLogEnabled()) return;
    BG3MFXFrameLogMethod(BG3MFXPresentNative);
    objc_setAssociatedObject(buffer,&nativePresentKey,drawable,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
// The Frame Generation presenter's own presents pass through these hooks too
// (they hook every queue's command buffers); they are not BG3 frames.
static void present(id self, SEL cmd, id drawable) {
    if([BG3MFXFramePresenter isPresentationThread]) { ((void(*)(id,SEL,id))original(self,cmd))(self,cmd,drawable); return; }
    BG3MFXRenderedFrames.fetch_add(1,std::memory_order_relaxed);
    if(deferPresent(self,cmd,drawable)) return;
    countPresent(drawable,cmd); logNativePresent(self,drawable);
    ((void(*)(id,SEL,id))original(self,cmd))(self,cmd,drawable);
}
static void presentTimed(id self, SEL cmd, id drawable, double time) {
    if([BG3MFXFramePresenter isPresentationThread]) { ((void(*)(id,SEL,id,double))original(self,cmd))(self,cmd,drawable,time); return; }
    BG3MFXRenderedFrames.fetch_add(1,std::memory_order_relaxed);
    if(deferPresent(self,cmd,drawable)) return;
    countPresent(drawable,cmd); logNativePresent(self,drawable);
    ((void(*)(id,SEL,id,double))original(self,cmd))(self,cmd,drawable,time);
}
static void commit(id self, SEL cmd) {
    if (labEnabled && labDumpCaptured) labWriteDumps(self);
    if (labEnabled) {
        labCommits.fetch_add(1,std::memory_order_relaxed);
        [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> done) {
            double span = done.GPUEndTime - done.GPUStartTime;
            if (span > 0 && span < 1) labGPUNanoseconds.fetch_add((uint64_t)(span*1e9),std::memory_order_relaxed);
        }];
    }
    if (id<MTLDrawable> shown=objc_getAssociatedObject(self,&nativePresentKey)) {
        objc_setAssociatedObject(self,&nativePresentKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CFTimeInterval committed=CACurrentMediaTime();
        if (BG3MFXFrameLogEnabled()) {
            [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> done){
                BG3MFXFrameLogGPU(done.GPUStartTime,done.GPUEndTime,committed,CACurrentMediaTime());
            }];
        }
        [shown addPresentedHandler:^(id<MTLDrawable> d){
            BG3MFXFrameLogShown(NO,d.presentedTime);
            if (d.presentedTime>0) BG3MFXFrameLogLatency(d.presentedTime-committed,0);
        }];
    }
    NSDictionary *request=objc_getAssociatedObject(self,&deferredPresentKey);
    NSDictionary *pair=objc_getAssociatedObject(self,&generatedPairKey);
    objc_setAssociatedObject(self,&deferredPresentKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self,&generatedPairKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id<CAMetalDrawable> drawable=request[@"drawable"];
    BOOL paired=drawable && pair && pair[@"target"]==drawable.texture;
    if (pair && !paired) [pair[@"presenter"] discardGeneratedTarget:pair[@"generated"] afterCommandBuffer:self];
    if (drawable) {
#ifndef BG3MFX_NO_TRACE
        // BG3's vsync option toggles displaySyncEnabled on its layer at runtime.
        static int lastDisplaySync=-1; int displaySync=drawable.layer.displaySyncEnabled;
        if (displaySync!=lastDisplaySync) {
            lastDisplaySync=displaySync; record(@{@"event":@"frameGenerationDisplaySync",@"enabled":@(displaySync)});
        }
#endif
        [[BG3MFXFramePresenter presenterForStandIn:drawable] submitStandIn:drawable generated:paired ? pair[@"generated"] : nil
            afterBuffer:self interval:[pair[@"interval"] doubleValue]];
        countPresent(drawable,cmd);
#ifndef BG3MFX_NO_TRACE
        // Includes any time this buffer waited on the GPU for Metal 4 work.
        [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> done){ recordFrameGPU(done); }];
        unsigned deferred=++deferredPresents; paired ? ++pairedPresents : ++replayedPresents;
        if (deferred<=3 || deferred%120==0)
            record(@{@"event":@"frameGenerationPresentSummary",@"deferred":@(deferred),
                @"paired":@(pairedPresents.load()),@"unpaired":@(replayedPresents.load())});
#endif
    }
    BG3MFXMetal4Commit(self,^{ ((void(*)(id,SEL))original(self,cmd))(self,cmd); });
}
// BG3 fixes its buffers' GPU order with -enqueue before encoding them; Metal 4
// submissions follow that order (GPUResources.h).
static void enqueueBuffer(id self, SEL cmd) {
    BG3MFXMetal4Enqueue(self,^{ ((void(*)(id,SEL))original(self,cmd))(self,cmd); });
}
// Frame Generation hands BG3 a stand-in instead of a real drawable; the
// presenter's own thread still receives real ones.
// BG3's own maximumDrawableCount (2 for double-buffered vsync) while Frame
// Generation holds the layer at 3.
static char bg3DrawableCountKey;
static thread_local bool ownDrawableCountWrite=false;
static void setLayerDrawableCount(CAMetalLayer *layer, NSUInteger count) {
    ownDrawableCountWrite=true; layer.maximumDrawableCount=count; ownDrawableCountWrite=false;
}
// While Frame Generation holds the layer, BG3's own changes (switching between
// double- and triple-buffered vsync) are recorded instead of applied.
static void layerSetMaximumDrawableCount(id self, SEL cmd, NSUInteger count) {
    if (!ownDrawableCountWrite && objc_getAssociatedObject(self,&bg3DrawableCountKey)) {
        objc_setAssociatedObject(self,&bg3DrawableCountKey,@(count),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        record(@{@"event":@"frameGenerationDrawableCount",@"bg3":@(count)});
        return;
    }
    ((void(*)(id,SEL,NSUInteger))original(self,cmd))(self,cmd,count);
}
static id layerNextDrawable(id self, SEL cmd) {
    if ([BG3MFXFramePresenter isPresentationThread]) return ((id(*)(id,SEL))original(self,cmd))(self,cmd);
    CAMetalLayer *layer=self;
    if (!metalFXEnabled || frameGenerationDeclined || !BG3MFXFrameGenerationEnabled()) {
        NSNumber *saved=objc_getAssociatedObject(layer,&bg3DrawableCountKey);
        if (saved) {
            objc_setAssociatedObject(layer,&bg3DrawableCountKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            setLayerDrawableCount(layer,saved.unsignedIntegerValue);
            record(@{@"event":@"frameGenerationDrawableCount",@"restored":saved});
        }
        BG3MFXFrameLogBuffering((unsigned)layer.maximumDrawableCount,0);
        BOOL logWait=BG3MFXFrameLogEnabled();
        CFTimeInterval waitStart=logWait ? CACurrentMediaTime() : 0;
        id drawable=((id(*)(id,SEL))original(self,cmd))(self,cmd);
        if (logWait) BG3MFXFrameLogDrawableWait(CACurrentMediaTime()-waitStart);
        return drawable;
    }
    // Each rendered frame becomes two presents, which needs three drawables
    // (Apple's frame interpolation guidance). BG3 only renders into stand-ins
    // here, so its double-buffered setting would just starve the presenter.
    // BG3's value is kept (and updated by the setter hook) to restore later.
    if (!objc_getAssociatedObject(layer,&bg3DrawableCountKey)) {
        objc_setAssociatedObject(layer,&bg3DrawableCountKey,@(layer.maximumDrawableCount),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        record(@{@"event":@"frameGenerationDrawableCount",@"bg3":@(layer.maximumDrawableCount),@"forced":@3});
    }
    if (layer.maximumDrawableCount!=3) setLayerDrawableCount(layer,3);
    BG3MFXFramePresenter *presenter;
    { std::lock_guard<std::recursive_mutex> lock(guard());
      if (!framePresenter || framePresenter.pixelFormat!=layer.pixelFormat) {
          NSError *error=nil;
          framePresenter=[[BG3MFXFramePresenter alloc] initWithDevice:layer.device format:layer.pixelFormat error:&error];
          if (!framePresenter) { declineFrameGeneration(error.localizedDescription ?: @"Could not initialize frame presentation.");
              return ((id(*)(id,SEL))original(self,cmd))(self,cmd); }
          framePresenter.failureHandler=^(NSError *e){declineFrameGeneration(e.localizedDescription ?: @"Metal could not present a generated frame.");};
#ifndef BG3MFX_NO_TRACE
          BG3MFXGPUTimingHook=recordGPUSubmission;
          framePresenter.presentedHandler=^(BOOL generated, CFTimeInterval time, CFTimeInterval target, double interval){
              recordDisplayed(generated,time,target,interval); };
#endif
          record(@{@"event":@"frameGenerationPresenterCreated",@"format":@(layer.pixelFormat),
              @"displaySync":@(layer.displaySyncEnabled),@"maximumDrawableCount":@(layer.maximumDrawableCount)});
      }
      presenter=framePresenter; }
    // BG3's requested buffering limits its stand-ins (two for double-buffered
    // vsync) while the real layer stays at three for the presenter.
    return [presenter nextStandInForLayer:layer
        limit:[objc_getAssociatedObject(layer,&bg3DrawableCountKey) unsignedIntegerValue]];
}
static id commandBuffer(id self, SEL cmd) {
    SEL actual = cmd;
    { std::lock_guard<std::recursive_mutex> lock(guard());
      if ((metalFXEnabled || (sceneProbe && !sceneProbeAttempts)) && cmd == sel_registerName("commandBufferWithUnretainedReferences"))
          actual = sel_registerName("commandBuffer"); }
    // Selection changes apply to the next command buffer. Sampling the live
    // menu independently at TAA and FSR could mix two render paths in one frame.
    int mode = BG3MFXSelectedScalingMode();
    if (labEnabled) if (int forced = labScaling.load(std::memory_order_relaxed); forced >= 1 && forced <= 3) mode = forced;
    id buffer = ((id(*)(id,SEL))original(self,actual))(self,actual);
    objc_setAssociatedObject(buffer,&bufferScalingModeKey,@(mode),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Frame Generation combines with every Upscaling Type: it uses the camera,
    // depth and motion captured at BG3's TAA pass.
    bool frameGenerationSelected=BG3MFXFrameGenerationEnabled();
    if (!frameGenerationSelected) frameGenerationDeclined=false;
    objc_setAssociatedObject(buffer,&frameGenerationModeKey,@(frameGenerationSelected && !frameGenerationDeclined),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(buffer,&generatedPairKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(buffer,&deferredPresentKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(buffer,&temporalFrameKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#ifndef BG3MFX_NO_TRACE
    objc_setAssociatedObject(buffer,&temporalPassHistoryKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#endif
    objc_setAssociatedObject(buffer,&sceneCameraKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(buffer,&deviceDepthKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    record(@{@"event": @"commandBuffer", @"method": NSStringFromSelector(cmd), @"actualMethod": NSStringFromSelector(actual),
             @"retainedReferences": @([buffer retainedReferences])});
    hook(buffer,"renderCommandEncoderWithDescriptor:",(IMP)renderEncoder);
    hook(buffer,"blitCommandEncoder",(IMP)blitEncoder);
    hook(buffer,"blitCommandEncoderWithDescriptor:",(IMP)blitEncoderDescriptor);
    hook(buffer,"computeCommandEncoder",(IMP)computeEncoder);
    hook(buffer,"computeCommandEncoderWithDispatchType:",(IMP)computeEncoderType);
    hook(buffer,"presentDrawable:",(IMP)present);
    hook(buffer,"presentDrawable:afterMinimumDuration:",(IMP)presentTimed);
    hook(buffer,"presentDrawable:atTime:",(IMP)presentTimed);
    hook(buffer,"commit",(IMP)commit);
    hook(buffer,"enqueue",(IMP)enqueueBuffer);
    if (metalFXEnabled) BG3MFXMetal4TrackBuffer(buffer);
    if (diagnostics) hook(buffer,"pushDebugGroup:",(IMP)group);
    return buffer;
}
static void instrumentQueue(id queue) {
    hook(queue,"commandBuffer",(IMP)commandBuffer);
    hook(queue,"commandBufferWithUnretainedReferences",(IMP)commandBuffer);
}
static id newQueue(id self, SEL cmd) {
    id queue = ((id(*)(id,SEL))original(self,cmd))(self,cmd);
    instrumentQueue(queue);
    return queue;
}
static id newQueueLimit(id self, SEL cmd, NSUInteger count) {
    id queue = ((id(*)(id,SEL,NSUInteger))original(self,cmd))(self,cmd,count);
    instrumentQueue(queue);
    return queue;
}
__attribute__((constructor)) static void start() {
    @autoreleasepool {
        if (diagnostics) seen = [NSMutableSet set];
        sceneProbe = diagnostics && getenv("BG3MFX_SCENE_PROBE") && strcmp(getenv("BG3MFX_SCENE_PROBE"),"1") == 0;
        metalFXEnabled = getenv("BG3MFX_ENABLE_METALFX") && strcmp(getenv("BG3MFX_ENABLE_METALFX"),"1") == 0;
        traceConstants = metalFXEnabled;
#ifndef BG3MFX_NO_TRACE
        if (const char *value = getenv("BG3MFX_TRACE_CONSTANTS"))
            traceConstants |= strcmp(value,"1") == 0;
#endif
        // Depth prepass trim (docs/dev/performance.md); needs the draw hooks.
        // BG3MFX_DEPTH_PREPASS_OPTIMIZATION=0 keeps BG3's full prepass for comparison.
        // Bind dedup; BG3MFX_RENDER_THREAD_OPTIMIZATIONS=0 forwards every bind for comparison.
        bindDedup = metalFXEnabled && !(getenv("BG3MFX_RENDER_THREAD_OPTIMIZATIONS") && strcmp(getenv("BG3MFX_RENDER_THREAD_OPTIMIZATIONS"),"0") == 0);
        redundantProbe = diagnostics && metalFXEnabled && getenv("BG3MFX_TRACE_REDUNDANT") && strcmp(getenv("BG3MFX_TRACE_REDUNDANT"),"1") == 0;
        prepassTrim = metalFXEnabled && !(getenv("BG3MFX_DEPTH_PREPASS_OPTIMIZATION") && strcmp(getenv("BG3MFX_DEPTH_PREPASS_OPTIMIZATION"),"0") == 0);
        if (const char *lab = getenv("BG3MFX_LAB"); lab && *lab) {
            labDirectory = [NSString stringWithUTF8String:lab].stringByExpandingTildeInPath;
            [NSFileManager.defaultManager createDirectoryAtPath:labDirectory withIntermediateDirectories:YES attributes:nil error:nil];
            labSkips = @[]; labEnabled = true;
            traceConstants = YES;  // installs the draw and dispatch hooks
            fprintf(stderr,"BG3 MetalFX lab mode: %s\n",labDirectory.UTF8String);
            BG3MFXLabInputStart(labDirectory);
            labRecording = true;
            if (!BG3MFXGPUTimingHook) BG3MFXGPUTimingHook = labMetal4Timing;
        }
        // Cluster buffer guard; BG3MFX_CLUSTER_BUFFER_GUARD=0 leaves BG3's bindings alone for comparison.
        clusterGuard = metalFXEnabled && !(getenv("BG3MFX_CLUSTER_BUFFER_GUARD") && strcmp(getenv("BG3MFX_CLUSTER_BUFFER_GUARD"),"0") == 0);
        if (diagnostics) {
            constantSamples = [NSMutableDictionary dictionary];
            shaderBufferSizes = [NSMutableDictionary dictionary];
        }
        if (diagnostics) {
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"bg3mfx-trace.jsonl"];
        const char *override = getenv("BG3MFX_TRACE");
        if (override) path = [NSString stringWithUTF8String:override];
        int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0600);
        output = fd >= 0 ? [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES] : nil;
        }
        if (metalFXEnabled && [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.larian.bg3"]) {
            NSError *menuError = nil;
            // Without the menu nothing selects MetalFX, so BG3 renders as usual.
            if (!BG3MFXInstallNativeMenu(menuReport,&menuError)) {
                NSString *reason = menuError.localizedDescription ?: @"The native integration could not be installed.";
                fprintf(stderr,"MetalFX could not start: %s\n",reason.UTF8String); fflush(stderr);
                record(@{@"event":@"nativeMenuInstallFailed",@"error":reason});
                showNotice(@"MetalFX could not start",[reason stringByAppendingString:
                    @"\n\nThe game continues without MetalFX and BG3MFX's other optimizations."]);
            }
        }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
#ifndef BG3MFX_NO_TRACE
        // Growth at a steady size means a set still holds textures BG3 replaced.
        BG3MFXResidencyHook = [](NSString *label, NSUInteger allocations, uint64_t bytes, NSUInteger added, BOOL replaced) {
            record(@{@"event":@"metal4Residency",@"label":label ?: @"",@"allocations":@(allocations),
                @"megabytes":@(bytes/1048576.0),@"added":@(added),@"replaced":@(replaced)});
        };
        NSMutableDictionary *startup = [@{@"event": @"start", @"mode": metalFXEnabled ? @"metalfx-menu" : @"diagnostic", @"device": device.name ?: @"unavailable",
                 @"spatial": @([MTLFXSpatialScalerDescriptor supportsDevice:device]),
                 @"temporal": @([MTLFXTemporalScalerDescriptor supportsDevice:device])} mutableCopy];
        record(startup);
#endif
        hook(device,"newCommandQueue",(IMP)newQueue);
        if (metalFXEnabled) {
            CAMetalLayer *layer=[CAMetalLayer layer];
            hook(layer,"nextDrawable",(IMP)layerNextDrawable);
            hook(layer,"setMaximumDrawableCount:",(IMP)layerSetMaximumDrawableCount);
        }
        hook(device,"newCommandQueueWithMaxCommandBufferCount:",(IMP)newQueueLimit);
        hook(device,"newRenderPipelineStateWithDescriptor:error:",(IMP)renderPipeline);
        hook(device,"newRenderPipelineStateWithDescriptor:options:reflection:error:",(IMP)renderPipelineOptions);
        hook(device,"newComputePipelineStateWithFunction:error:",(IMP)computePipeline);
        if (prepassTrim) hook(device,"newDepthStencilStateWithDescriptor:",(IMP)depthStencilStateHook);
        // Multiple GPUs may use different concrete driver classes.
        for (id<MTLDevice> other in MTLCopyAllDevices()) {
            hook(other,"newCommandQueue",(IMP)newQueue);
            hook(other,"newCommandQueueWithMaxCommandBufferCount:",(IMP)newQueueLimit);
            hook(other,"newRenderPipelineStateWithDescriptor:error:",(IMP)renderPipeline);
            hook(other,"newRenderPipelineStateWithDescriptor:options:reflection:error:",(IMP)renderPipelineOptions);
            hook(other,"newComputePipelineStateWithFunction:error:",(IMP)computePipeline);
            if (prepassTrim) hook(other,"newDepthStencilStateWithDescriptor:",(IMP)depthStencilStateHook);
        }
    }
}
// Read-only fixture access; a real BG3 process cannot expose its generated pair.
#if !defined(BG3MFX_NO_TRACE) || defined(BG3MFX_STANDALONE_TEST_HOOKS)
extern "C" NSDictionary *BG3MFXStandaloneGeneratedPair(id<MTLCommandBuffer> buffer) {
    if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.larian.bg3"]) return nil;
    return objc_getAssociatedObject(buffer,&generatedPairKey);
}
extern "C" NSUInteger BG3MFXStandaloneTemporalScalersCreated(void) {
    if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.larian.bg3"]) return 0;
    return temporalScalersCreated.load();
}
extern "C" NSUInteger BG3MFXStandalonePresentedPairs(void) {
    if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.larian.bg3"]) return 0;
    return framePresenter.presentedPairs;
}
#endif
