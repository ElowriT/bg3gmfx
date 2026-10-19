#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <stdlib.h>

// Split-screen fog: a DefaultVS + DeferredFog_*_PS pipeline drawn into the right
// half of the target must see render-target UVs (texCoord * g_ViewportScale +
// g_ViewportOffset), as BG3's PPDefaultVS passes provide; any other pass keeps
// DefaultVS's view-relative texCoord. BG3MFX_SPLIT_SCREEN_FOG=0 turns the fix off.
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        if (!dlopen(argv[1], RTLD_NOW)) { fprintf(stderr, "%s\n", dlerror()); return 1; }
        bool disabled = getenv("BG3MFX_SPLIT_SCREEN_FOG") && !strcmp(getenv("BG3MFX_SPLIT_SCREEN_FOG"),"0");
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSError *error = nil;
        // Stand-ins with BG3's interfaces: float2 position and texCoord attributes,
        // a passthrough vertex function and a texCoord varying.
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct In { float2 position [[attribute(0)]]; float2 texCoord [[attribute(1)]]; };\n"
            "struct Out { float4 position [[position]]; float2 texCoord; };\n"
            "vertex Out DefaultVS(In in [[stage_in]]) { return { float4(in.position,1,1), in.texCoord }; }\n"
            "fragment float4 DeferredFog_Smoke_PS(Out in [[stage_in]]) { return float4(in.texCoord,0,1); }\n"
            "fragment float4 OtherPass_PS(Out in [[stage_in]]) { return float4(in.texCoord,0,1); }\n";
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        if (!library) { fprintf(stderr,"%s\n",error.description.UTF8String); return 3; }
        MTLVertexDescriptor *vertex = [MTLVertexDescriptor vertexDescriptor];
        vertex.attributes[0].format = MTLVertexFormatFloat2;
        vertex.attributes[1].format = MTLVertexFormatFloat2; vertex.attributes[1].offset = 8;
        vertex.attributes[5].format = MTLVertexFormatFloat; vertex.attributes[5].offset = 16;
        vertex.layouts[0].stride = 20;
        id<MTLRenderPipelineState> pipelines[2];
        NSString *fragments[2] = {@"DeferredFog_Smoke_PS",@"OtherPass_PS"};
        for (int i = 0; i < 2; ++i) {
            MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
            desc.vertexFunction = [library newFunctionWithName:@"DefaultVS"];
            desc.fragmentFunction = [library newFunctionWithName:fragments[i]];
            desc.vertexDescriptor = vertex;
            desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
            pipelines[i] = i ? [device newRenderPipelineStateWithDescriptor:desc error:&error]
                : [device newRenderPipelineStateWithDescriptor:desc options:MTLPipelineOptionNone reflection:nil error:&error];
            if (!pipelines[i]) { fprintf(stderr,"%s\n",error.description.UTF8String); return 4; }
        }
        // BG3's fullscreen triangle: texCoord 0..1 across whichever viewport is set.
        const float triangle[] = {-1,1, 0,0, 0,  3,1, 2,0, 1,  -1,-3, 0,2, 2};
        // g_ViewportScale and g_ViewportOffset of the right view (the rest of the 168-byte block unused here).
        float viewport[42] = {0.5f,1, 0.5f,0};
        MTLTextureDescriptor *textureDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:8 height:2 mipmapped:NO];
        textureDesc.usage = MTLTextureUsageRenderTarget; textureDesc.storageMode = MTLStorageModeShared;
        id<MTLCommandQueue> queue = [device newCommandQueue];
        float expected[2] = {disabled ? 0.375f : 0.6875f, 0.375f};  // pixel 5: local u 1.5/4
        for (int i = 0; i < 2; ++i) {
            id<MTLTexture> target = [device newTextureWithDescriptor:textureDesc];
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
            pass.colorAttachments[0].texture = target;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLCommandBuffer> buffer = [queue commandBuffer];
            id<MTLRenderCommandEncoder> render = [buffer renderCommandEncoderWithDescriptor:pass];
            [render setViewport:(MTLViewport){4,0,4,2,0,1}];
            [render setRenderPipelineState:pipelines[i]];
            [render setVertexBytes:triangle length:sizeof(triangle) atIndex:0];
            [render setVertexBytes:viewport length:sizeof(viewport) atIndex:9];
            [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [render endEncoding];
            [buffer commit]; [buffer waitUntilCompleted];
            float pixel[4] = {};
            [target getBytes:pixel bytesPerRow:8*16 fromRegion:MTLRegionMake2D(5,0,1,1) mipmapLevel:0];
            if (fabsf(pixel[0]-expected[i]) > 1e-4f) {
                fprintf(stderr,"%s saw texCoord.x %g, expected %g\n",fragments[i].UTF8String,pixel[0],expected[i]); return 10+i;
            }
        }
        printf(disabled ? "Split-screen fog fix disabled: the fog pass keeps view-relative UVs.\n"
                        : "The split-screen fog pass received render-target UVs; other passes were unchanged.\n");
    }
    return 0;
}
