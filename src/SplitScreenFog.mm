#import "SplitScreenFog.h"
#include <cstdlib>
#include <cstring>
#include <mutex>

// The game binds its Viewport constants (g_ViewportScale, then g_ViewportOffset)
// to vertex buffer 9 for every full-screen pass. The varying keeps the game's
// member name so it links to the fragment shader's texCoord input.
static const char *const viewportVertexSource = R"metal(
#include <metal_stdlib>
using namespace metal;
struct BG3MFXViewport { float2 scale; float2 offset; };
struct BG3MFXFullscreenIn { float2 position [[attribute(0)]]; float2 texCoord [[attribute(1)]]; };
struct BG3MFXFullscreenOut { float4 position [[position]]; float2 texCoord; };
vertex BG3MFXFullscreenOut BG3MFXViewportVS(BG3MFXFullscreenIn in [[stage_in]],
                                            constant BG3MFXViewport &viewport [[buffer(9)]]) {
    return { float4(in.position, 1.0, 1.0), in.texCoord * viewport.scale + viewport.offset };
}
)metal";

static bool fixEnabled() {
    static const bool enabled = [] {
        const char *value = getenv("BG3MFX_SPLIT_SCREEN_FOG");
        return !value || strcmp(value, "0") != 0;
    }();
    return enabled;
}

static id<MTLFunction> viewportVertex(id<MTLDevice> device) {
    static std::mutex lock;
    static id<MTLDevice> compiledFor;
    static id<MTLFunction> function;
    std::lock_guard<std::mutex> hold(lock);
    if (compiledFor != device) {
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:@(viewportVertexSource) options:nil error:&error];
        function = [library newFunctionWithName:@"BG3MFXViewportVS"];
        compiledFor = device;
        if (!function) NSLog(@"BG3 MetalFX: split-screen fog fix unavailable: %@", error.localizedDescription);
    }
    return function;
}

MTLRenderPipelineDescriptor *BG3MFXSplitScreenFogDescriptor(id<MTLDevice> device, MTLRenderPipelineDescriptor *desc) {
    if (!fixEnabled() || !device || ![desc.fragmentFunction.name hasPrefix:@"DeferredFog_"] ||
        ![desc.vertexFunction.name isEqualToString:@"DefaultVS"]) return nil;
    MTLVertexDescriptor *vertex = desc.vertexDescriptor;
    if (vertex.attributes[0].format != MTLVertexFormatFloat2 || vertex.attributes[1].format != MTLVertexFormatFloat2) return nil;
    id<MTLFunction> function = viewportVertex(device);
    if (!function) return nil;
    MTLRenderPipelineDescriptor *fixed = [desc copy];
    fixed.vertexFunction = function;
    return fixed;
}
