#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

static IMP earlierCompute;
static id lateComputeWrapper(id self, SEL cmd, MTLDispatchType type) {
    return ((id(*)(id,SEL,MTLDispatchType))earlierCompute)(self,cmd,type);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        if (!dlopen(argv[1], RTLD_NOW)) { fprintf(stderr, "%s\n", dlerror()); return 1; }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return 3;
        NSError *error = nil;
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 smokeVS(uint id [[vertex_id]]) { float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[id],0,1); }\n"
            "kernel void BG3MFXDispatchSmoke(device uint *dst [[buffer(0)]], uint p [[thread_position_in_grid]]) { if (p < 64) dst[p] += p+17; }\n"
            "fragment float4 BG3MFXConstantsSmoke(constant float4 &color [[buffer(0)]]) { return color; }\n";
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        if (!library) { fprintf(stderr,"%s\n",error.description.UTF8String); return 5; }
        MTLRenderPipelineDescriptor *pipelineDesc = [MTLRenderPipelineDescriptor new];
        pipelineDesc.vertexFunction = [library newFunctionWithName:@"smokeVS"];
        pipelineDesc.fragmentFunction = [library newFunctionWithName:@"BG3MFXConstantsSmoke"];
        pipelineDesc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pipelineDesc error:&error];
        if (!pipeline) return 6;
        MTLTextureDescriptor *textureDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
        textureDesc.usage = MTLTextureUsageRenderTarget;
        textureDesc.storageMode = MTLStorageModeShared;
        id<MTLTexture> texture = [device newTextureWithDescriptor:textureDesc];
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
        pass.colorAttachments[0].texture = texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> buffer = [queue commandBufferWithUnretainedReferences];
        const char *probe = getenv("BG3MFX_SCENE_PROBE");
        BOOL probeEnabled = probe && strcmp(probe,"1") == 0;
        if (buffer.retainedReferences != probeEnabled) return 8;
        id<MTLComputeCommandEncoder> encoder = [buffer computeCommandEncoder];
        encoder.label = @"BG3MFX smoke test";
        id<MTLComputePipelineState> compute = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"BG3MFXDispatchSmoke"] error:&error];
        if (!compute) return 9;
        uint32_t zeros[64] = {};
        id<MTLBuffer> computed = [device newBufferWithBytes:zeros length:sizeof(zeros) options:MTLResourceStorageModeShared];
        [encoder setComputePipelineState:compute]; [encoder setBuffer:computed offset:0 atIndex:0];
        [encoder dispatchThreads:MTLSizeMake(64,1,1) threadsPerThreadgroup:MTLSizeMake(4,1,1)];
        [encoder dispatchThreadgroups:MTLSizeMake(16,1,1) threadsPerThreadgroup:MTLSizeMake(4,1,1)];
        [encoder endEncoding];
        encoder = [buffer computeCommandEncoderWithDispatchType:MTLDispatchTypeConcurrent];
        [encoder setComputePipelineState:compute]; [encoder setBuffer:computed offset:0 atIndex:0];
        [encoder dispatchThreadgroups:MTLSizeMake(16,1,1) threadsPerThreadgroup:MTLSizeMake(4,1,1)];
        [encoder endEncoding];
        // Model a later profiler wrapper that keeps the trace's old IMP.
        // Refreshing the hook must preserve that wrapper without recursing.
        SEL computeSelector = sel_registerName("computeCommandEncoderWithDispatchType:");
        Class bufferClass = object_getClass(buffer);
        Method computeMethod = class_getInstanceMethod(bufferClass,computeSelector);
        earlierCompute = method_getImplementation(computeMethod);
        class_replaceMethod(bufferClass,computeSelector,(IMP)lateComputeWrapper,method_getTypeEncoding(computeMethod));
        id<MTLRenderCommandEncoder> render = [buffer renderCommandEncoderWithDescriptor:pass];
        [render setRenderPipelineState:pipeline];
        float colors[8] = {1,0,0,1, 0.25,0.5,0.75,1};
        [render setFragmentBytes:colors+4 length:16 atIndex:0];
        [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [render endEncoding];
        pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        render = [buffer renderCommandEncoderWithDescriptor:pass];
        [render setRenderPipelineState:pipeline];
        id<MTLBuffer> constants = [device newBufferWithBytes:colors length:sizeof(colors) options:MTLResourceStorageModeShared];
        id<MTLBuffer> buffers[] = {constants};
        NSUInteger offsets[] = {0};
        [render setFragmentBuffers:buffers offsets:offsets withRange:NSMakeRange(0,1)];
        [render setFragmentBufferOffset:16 atIndex:0];
        [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3 instanceCount:1];
        [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3 instanceCount:1 baseInstance:0];
        uint16_t indices[] = {0,1,2};
        id<MTLBuffer> indexBuffer = [device newBufferWithBytes:indices length:sizeof(indices) options:MTLResourceStorageModeShared];
        [render drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:3 indexType:MTLIndexTypeUInt16 indexBuffer:indexBuffer indexBufferOffset:0];
        [render drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:3 indexType:MTLIndexTypeUInt16 indexBuffer:indexBuffer indexBufferOffset:0 instanceCount:1];
        [render drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:3 indexType:MTLIndexTypeUInt16 indexBuffer:indexBuffer indexBufferOffset:0 instanceCount:1 baseVertex:0 baseInstance:0];
        [render endEncoding];
        encoder = [buffer computeCommandEncoderWithDispatchType:MTLDispatchTypeConcurrent];
        [encoder setComputePipelineState:compute]; [encoder setBuffer:computed offset:0 atIndex:0];
        [encoder dispatchThreads:MTLSizeMake(64,1,1) threadsPerThreadgroup:MTLSizeMake(4,1,1)];
        [encoder endEncoding];
        // The Steam overlay exchanges -commit and every present variant with
        // steamoverlay_<name> methods of its own, which call that selector, so
        // the runtime's hooks run under the overlay's selectors. Both timed
        // presents share one hook replacement; with VSync BG3 uses one of them.
        Class committedClass = object_getClass(buffer);
        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.device = device; layer.pixelFormat = MTLPixelFormatBGRA8Unorm; layer.drawableSize = CGSizeMake(64,64);
        id<CAMetalDrawable> drawables[3] = {[layer nextDrawable],[layer nextDrawable],[layer nextDrawable]};
        if (!drawables[0] || !drawables[1] || !drawables[2]) return 11;
        auto exchange = [&](const char *name, id block, const char *types) {
            SEL selector = sel_registerName(name);
            SEL overlay = sel_registerName([@"steamoverlay_" stringByAppendingString:@(name)].UTF8String);
            class_addMethod(committedClass, overlay, imp_implementationWithBlock(block), types);
            method_exchangeImplementations(class_getInstanceMethod(committedClass, selector),
                                           class_getInstanceMethod(committedClass, overlay));
        };
        SEL overlayCommit = sel_registerName("steamoverlay_commit"), overlayPresent = sel_registerName("steamoverlay_presentDrawable:");
        SEL overlayAfter = sel_registerName("steamoverlay_presentDrawable:afterMinimumDuration:");
        SEL overlayAt = sel_registerName("steamoverlay_presentDrawable:atTime:");
        exchange("commit", ^(id self) { ((void(*)(id,SEL))objc_msgSend)(self, overlayCommit); }, "v@:");
        exchange("presentDrawable:", ^(id self, id shown) { ((void(*)(id,SEL,id))objc_msgSend)(self, overlayPresent, shown); }, "v@:@");
        exchange("presentDrawable:afterMinimumDuration:", ^(id self, id shown, CFTimeInterval duration) {
            ((void(*)(id,SEL,id,CFTimeInterval))objc_msgSend)(self, overlayAfter, shown, duration); }, "v@:@d");
        exchange("presentDrawable:atTime:", ^(id self, id shown, CFTimeInterval time) {
            ((void(*)(id,SEL,id,CFTimeInterval))objc_msgSend)(self, overlayAt, shown, time); }, "v@:@d");
        [buffer presentDrawable:drawables[0]];
        [buffer presentDrawable:drawables[1] afterMinimumDuration:1.0/60];
        [buffer presentDrawable:drawables[2] atTime:CACurrentMediaTime()];
        [buffer commit];
        [buffer waitUntilCompleted];
        if (buffer.status != MTLCommandBufferStatusCompleted) return 4;
        for (NSUInteger i=0; i<64; ++i) if (((uint32_t *)computed.contents)[i] != 4*(i+17)) return 10;
        uint8_t pixel[4];
        [texture getBytes:pixel bytesPerRow:4 fromRegion:MTLRegionMake2D(32,32,1,1) mipmapLevel:0];
        if (pixel[0] < 62 || pixel[0] > 65 || pixel[1] < 126 || pixel[1] > 129 || pixel[2] < 190 || pixel[2] > 193) return 7;
        puts("Runtime loaded; hooked Metal command buffer completed, also with -commit and every present exchanged as the Steam overlay does");
    }
    return 0;
}
