#import "common/gpu/MetalFXPipeline.h"
#import "common/gpu/GPUResources.h"
#include <cmath>
#include <cstdio>

// Several in-flight producer/scaler/consumer chains, followed by immediate
// backend destruction. Private inputs must be produced by GPU work, not CPU
// initialization, so a missing cross-queue dependency cannot silently pass.
int main() { @autoreleasepool {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    if (!device) return 1;
    NSError *error=nil;
    BG3MFXPipeline *pipeline=[[BG3MFXPipeline alloc] initWithDevice:device inputWidth:256 inputHeight:128
        outputWidth:512 outputHeight:256 colorFormat:MTLPixelFormatRGBA16Float depthFormat:MTLPixelFormatR32Float
        motionFormat:MTLPixelFormatRG16Float outputFormat:MTLPixelFormatRGBA16Float error:&error];
    if(!pipeline) { fprintf(stderr,"%s\n",error.description.UTF8String);return 2; }
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void Fill(texture2d<float,access::write> c [[texture(0)]],texture2d<float,access::write> d [[texture(1)]],"
        "texture2d<float,access::write> m [[texture(2)]],constant float &v [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {"
        "c.write(float4(v,v*0.5,v*0.25,1),p);d.write(float4(0.5),p);m.write(float4(0),p);}";
    id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
    id<MTLComputePipelineState> fill=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"Fill"] error:&error];
    if(!fill) return 3;
    id<MTLCommandQueue> queue=[device newCommandQueue];
    NSMutableArray *buffers=[NSMutableArray array], *readbacks=[NSMutableArray array];
    BOOL metal4=pipeline.usesMetal4;
    for(unsigned frame=0;frame<8;++frame) { @autoreleasepool {
        id<MTLTexture> inputs[3];
        MTLPixelFormat formats[]={MTLPixelFormatRGBA16Float,MTLPixelFormatR32Float,MTLPixelFormatRG16Float};
        for(unsigned i=0;i<3;++i) {
            MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:formats[i] width:256 height:128 mipmapped:NO];
            d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
            inputs[i]=[device newTextureWithDescriptor:d];
        }
        id<MTLCommandBuffer> b=[queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder=[b computeCommandEncoder];
        float value=0.1f*(frame+1);
        [encoder setComputePipelineState:fill];
        for(unsigned i=0;i<3;++i) [encoder setTexture:inputs[i] atIndex:i];
        [encoder setBytes:&value length:sizeof(value) atIndex:0];
        [encoder dispatchThreads:MTLSizeMake(256,128,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[encoder endEncoding];
        BG3MFXFrameParameters p={};p.motionScaleX=p.motionScaleY=1;p.reset=YES;p.depthReversed=YES;
        BG3MFXFrame *result=[pipeline encodeColor:inputs[0] depth:inputs[1] motion:inputs[2] parameters:p commandBuffer:b error:&error];
        if(!result) { fprintf(stderr,"%s\n",error.description.UTF8String);return 4; }
        id<MTLBuffer> pixels=[device newBufferWithLength:512*256*8 options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> blit=[b blitCommandEncoder];
        [blit copyFromTexture:result.rendered sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(512,256,1) toBuffer:pixels destinationOffset:0 destinationBytesPerRow:4096 destinationBytesPerImage:pixels.length];
        [blit endEncoding];[buffers addObject:b];[readbacks addObject:pixels];[b commit];
    }}
    pipeline=nil; // Submission ownership must outlive the backend and its cache.
    for(unsigned frame=0;frame<8;++frame) {
        id<MTLCommandBuffer> b=buffers[frame];[b waitUntilCompleted];
        if(b.status!=MTLCommandBufferStatusCompleted) return 5;
        const __fp16 *data=(const __fp16 *)[readbacks[frame] contents];
        for(unsigned y=32;y<224;y+=29) for(unsigned x=32;x<480;x+=31) {
            float v=data[(y*512+x)*4], expected=0.1f*(frame+1);
            if(!std::isfinite(v) || std::abs(v-expected)>0.02f) {
                fprintf(stderr,"Frame %u: stale/invalid output %g, expected %g\n",frame,v,expected);return 6;
            }
        }
    }
    if(metal4) {
        // Submission order: BG3 encodes its buffers on several threads, then
        // fixes their GPU order with -enqueue and commits them. Upscaling
        // encoded into the later buffer first must not leave the earlier one
        // waiting on the GPU for it, and a buffer that is never committed must
        // not hold up later ones.
        BG3MFXPipeline *ordered=[[BG3MFXPipeline alloc] initWithDevice:device inputWidth:256 inputHeight:128
            outputWidth:512 outputHeight:256 colorFormat:MTLPixelFormatRGBA16Float depthFormat:MTLPixelFormatR32Float
            motionFormat:MTLPixelFormatRG16Float outputFormat:MTLPixelFormatRGBA16Float error:&error];
        if(!ordered) return 7;
        __block NSError *gpuError=nil;
        ordered.gpuFailureHandler=^(NSError *failure) { gpuError=failure; };
        auto upscale=^BOOL(id<MTLCommandBuffer> b) {
            id<MTLTexture> inputs[3];
            MTLPixelFormat formats[]={MTLPixelFormatRGBA16Float,MTLPixelFormatR32Float,MTLPixelFormatRG16Float};
            for(unsigned i=0;i<3;++i) {
                MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:formats[i] width:256 height:128 mipmapped:NO];
                d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
                inputs[i]=[device newTextureWithDescriptor:d];
            }
            id<MTLComputeCommandEncoder> encoder=[b computeCommandEncoder];
            float value=0.5f;
            [encoder setComputePipelineState:fill];
            for(unsigned i=0;i<3;++i) [encoder setTexture:inputs[i] atIndex:i];
            [encoder setBytes:&value length:sizeof(value) atIndex:0];
            [encoder dispatchThreads:MTLSizeMake(256,128,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];[encoder endEncoding];
            BG3MFXFrameParameters p={};p.motionScaleX=p.motionScaleY=1;p.depthReversed=YES;
            NSError *encodeError=nil;
            if([ordered encodeColor:inputs[0] depth:inputs[1] motion:inputs[2] parameters:p commandBuffer:b error:&encodeError]) return YES;
            fprintf(stderr,"%s\n",encodeError.description.UTF8String); return NO;
        };
        id<MTLCommandBuffer> first=[queue commandBuffer], second=[queue commandBuffer], dropped=[queue commandBuffer], last=[queue commandBuffer];
        for(id<MTLCommandBuffer> b in @[first,second,dropped,last]) BG3MFXMetal4TrackBuffer(b);
        uint64_t before=BG3MFXMetal4Reordered();
        NSDate *start=[NSDate date];
        if(!upscale(second) || !upscale(first) || !upscale(dropped)) return 8;
        BG3MFXMetal4Enqueue(first,^{[first enqueue];});
        BG3MFXMetal4Enqueue(second,^{[second enqueue];});
        BG3MFXMetal4Commit(second,^{[second commit];});
        BG3MFXMetal4Commit(first,^{[first commit];});
        if(!upscale(last)) return 8;
        BG3MFXMetal4Commit(last,^{[last commit];});
        for(id<MTLCommandBuffer> b in @[first,second,last]) {
            [b waitUntilCompleted];
            if(b.status!=MTLCommandBufferStatusCompleted) {
                fprintf(stderr,"Ordered submission did not complete: %s\n",b.error.description.UTF8String);return 9;
            }
        }
        // Out of order, the scaler waits on itself until the GPU times it out.
        if(gpuError || -start.timeIntervalSinceNow>1.5) {
            fprintf(stderr,"Reordered upscaling stalled for %.1f s: %s\n",-start.timeIntervalSinceNow,gpuError.description.UTF8String ?: "no error");return 11;
        }
        if(BG3MFXMetal4Reordered()-before!=1) {
            fprintf(stderr,"Expected one reordered submission, saw %llu\n",(unsigned long long)(BG3MFXMetal4Reordered()-before));return 10;
        }
    }
    printf("%s bridge: eight in-flight GPU producers, scalers and consumers passed after backend destruction%s.\n",metal4 ? "Metal4" : "Metal3",
        metal4 ? "; submissions followed enqueue order and skipped an uncommitted buffer" : "");
    return 0;
}}
