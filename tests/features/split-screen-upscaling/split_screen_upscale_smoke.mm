#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <dlfcn.h>
#include <algorithm>
#include <cmath>
#include <cstring>

// Split screen: BG3 renders two views side by side into shared textures (each
// pass with its view's viewport and Viewport constants), then runs FSR and RCAS
// over the whole frame once per view. MetalFX Spatial and Temporal must upscale
// each view on its own (Temporal with a scaler, and so a history, per view),
// write only that view's half, and never blend the two halves at the seam.
// "frame-generation": with Frame Generation, each view is also interpolated on
// its own (an interpolator per view), and the generated frame composes like
// the real one in both halves.
static id<MTLTexture> texture(id<MTLDevice> device, NSUInteger width, NSUInteger height, MTLPixelFormat format, MTLTextureUsage usage) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
    d.storageMode = MTLStorageModePrivate; d.usage = usage;
    return [device newTextureWithDescriptor:d];
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2 && !(argc == 3 && !strcmp(argv[2],"frame-generation"))) return 1;
        bool fg = argc == 3;
        setenv("BG3MFX_ENABLE_METALFX","1",1);
        void *runtime = dlopen(argv[1],RTLD_NOW | RTLD_LOCAL);
        if (!runtime) { fprintf(stderr,"%s\n",dlerror()); return 2; }
        auto select = (BOOL(*)(int))dlsym(runtime,"BG3MFXSetStandaloneScalingMode");
        auto created = (NSUInteger(*)(void))dlsym(runtime,"BG3MFXStandaloneTemporalScalersCreated");
        auto setFrameGeneration = (BOOL(*)(BOOL))dlsym(runtime,"BG3MFXSetStandaloneFrameGeneration");
        auto pair = (NSDictionary *(*)(id<MTLCommandBuffer>))dlsym(runtime,"BG3MFXStandaloneGeneratedPair");
        auto presented = (NSUInteger(*)(void))dlsym(runtime,"BG3MFXStandalonePresentedPairs");
        auto interpolators = (NSUInteger(*)(void))dlsym(runtime,"BG3MFXStandaloneFrameInterpolatorsCreated");
        if (!select || !created || !setFrameGeneration || !pair || !presented || !interpolators) return 3;
        const char *sharpeningSetting = getenv("BG3MFX_METALFX_SHARPENING");
        bool sharpening = !sharpeningSetting || strcmp(sharpeningSetting,"0");
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSError *error = nil;
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 Fullscreen(uint id [[vertex_id]]) {float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[id],0,1);}\n"
            "fragment float LinearizeDepth(float4 p [[position]], depth2d<float> src [[texture(0)]]) {"
            "constexpr sampler s(coord::pixel,filter::nearest);return src.sample(s,p.xy);}\n"
            "fragment float2 VelocityBufferCamera_PS() {return float2(0);}\n"
            "fragment float4 PPTAA_PS(float4 p [[position]], texture2d<float> src [[texture(0)]]) {return float4(src.read(uint2(p.xy)).rgb+0.25,1);}\n"
            "fragment float4 FSR_Tonemap(float4 p [[position]], texture2d<float> src [[texture(0)]]) {float3 c=src.read(uint2(p.xy)).rgb;return float4(c/(1+max(c.r,max(c.g,c.b))),1);}\n"
            "fragment float4 PPToneMap_LUT(float4 p [[position]], texture2d<float> src [[texture(0)]]) {return float4(src.read(uint2(p.xy)).rgb*0.5,1);}\n"
            // Like BG3's: a quad strip with texture coordinates over the whole output, once for both views.
            "struct Q{float4 p [[position]];float2 uv;};vertex Q Quad(uint i [[vertex_id]]){float2 c=float2(i&1,i>>1);return {float4(c*2-1,0,1),float2(c.x,1-c.y)};}\n"
            "struct C{float4 tint;};fragment float4 CombineUI(Q q [[stage_in]],texture2d<float> scene [[texture(0)]],texture2d<float> ui [[texture(1)]],constant C &c [[buffer(0)]],sampler s [[sampler(0)]])"
            "{return float4(scene.sample(s,q.uv).rgb*.75+ui.sample(s,q.uv).rgb*.25,1)*c.tint;}\n"
            // Two views: the left half one color, the right half another.
            "kernel void Fill(texture2d<float,access::write> color [[texture(0)]], texture2d<float,access::write> motion [[texture(1)]], uint2 p [[thread_position_in_grid]]) {"
            "color.write(p.x < color.get_width()/2 ? float4(0.5,0.75,1.0,1) : float4(1.0,0.25,0.5,1),p);motion.write(float4(0),p);}\n"
            "kernel void FSR(texture2d<float,access::read> src [[texture(0)]], texture2d<float,access::write> dst [[texture(1)]], device atomic_uint *count [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {"
            "if(all(p==uint2(0))) atomic_fetch_add_explicit(count,1,memory_order_relaxed);dst.write(src.read(p/2),p);}\n"
            "kernel void FSR_RCAS(texture2d<float,access::read> src [[texture(0)]], texture2d<float,access::write> dst [[texture(2)]], device atomic_uint *count [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {"
            "if(all(p==uint2(0))) atomic_fetch_add_explicit(count+1,1,memory_order_relaxed);if(p.x>=dst.get_width()/2) atomic_fetch_add_explicit(count+2,1,memory_order_relaxed);"
            "float3 c=src.read(p).rgb;dst.write(float4(c/(1-max(c.r,max(c.g,c.b))),1),p);}\n"
            "kernel void Read(texture2d<float,access::read> src [[texture(0)]], device float4 *out [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {out[p.y*src.get_width()+p.x]=src.read(p);}";
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        if (!library) { fprintf(stderr,"%s\n",error.description.UTF8String); return 4; }
        NSMutableArray *compute = [NSMutableArray array];
        for (NSString *name in @[@"Fill",@"FSR",@"FSR_RCAS",@"Read"]) {
            id state = [device newComputePipelineStateWithFunction:[library newFunctionWithName:name] error:&error];
            if (!state) return 5; [compute addObject:state];
        }
        NSMutableArray *render = [NSMutableArray array];
        for (NSString *name in @[@"LinearizeDepth",@"PPTAA_PS",@"VelocityBufferCamera_PS",@"FSR_Tonemap",@"PPToneMap_LUT",@"CombineUI"]) {
            MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
            d.vertexFunction = [library newFunctionWithName:[name isEqualToString:@"CombineUI"] ? @"Quad" : @"Fullscreen"]; d.fragmentFunction = [library newFunctionWithName:name];
            d.colorAttachments[0].pixelFormat = [name isEqualToString:@"LinearizeDepth"] ? MTLPixelFormatR32Float : [name isEqualToString:@"VelocityBufferCamera_PS"] ? MTLPixelFormatRG16Float :
                [name isEqualToString:@"PPToneMap_LUT"] ? MTLPixelFormatRGB10A2Unorm : [name isEqualToString:@"CombineUI"] ? MTLPixelFormatBGRA8Unorm : MTLPixelFormatRG11B10Float;
            id state = [device newRenderPipelineStateWithDescriptor:d error:&error];
            if (!state) { fprintf(stderr,"%s\n",error.description.UTF8String); return 6; } [render addObject:state];
        }
        const NSUInteger W = 256, H = 256, OW = 512, OH = 512;
        MTLTextureUsage rw = MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite;
        id<MTLTexture> color = texture(device,W,H,MTLPixelFormatRG11B10Float,rw);
        id<MTLTexture> motion = texture(device,W,H,MTLPixelFormatRG16Float,rw|MTLTextureUsageRenderTarget);
        id<MTLTexture> depth = texture(device,W,H,MTLPixelFormatDepth32Float_Stencil8,MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget);
        id<MTLTexture> linearDepth = texture(device,W,H,MTLPixelFormatR32Float,MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget);
        id<MTLTexture> taa = texture(device,W,H,MTLPixelFormatRG11B10Float,rw|MTLTextureUsageRenderTarget);
        id<MTLTexture> tonemapped = texture(device,W,H,MTLPixelFormatRG11B10Float,rw|MTLTextureUsageRenderTarget);
        id<MTLTexture> graded = texture(device,W,H,MTLPixelFormatRG11B10Float,rw|MTLTextureUsageRenderTarget);
        id<MTLTexture> scaled = texture(device,OW,OH,MTLPixelFormatRGBA16Float,rw);
        id<MTLTexture> output = texture(device,OW,OH,MTLPixelFormatRG11B10Float,rw);
        id<MTLBuffer> pixels = [device newBufferWithLength:OW*OH*sizeof(float)*4 options:MTLResourceStorageModeShared];
        // Frame Generation: BG3 tone-maps each view into the final scene, then composes it with the UI once.
        id<MTLTexture> scene = texture(device,OW,OH,MTLPixelFormatRGB10A2Unorm,MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget);
        id<MTLTexture> ui = texture(device,OW,OH,MTLPixelFormatRGBA8Unorm,MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget);
        id<MTLBuffer> vertices = [device newBufferWithLength:80 options:MTLResourceStorageModeShared];
        id<MTLSamplerState> sampler = [device newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];
        id<MTLBuffer> composites[2] = {[device newBufferWithLength:OW*OH*4 options:MTLResourceStorageModeShared],
                                       [device newBufferWithLength:OW*OH*4 options:MTLResourceStorageModeShared]};
        CAMetalLayer *layer = [CAMetalLayer layer]; layer.device = device; layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = NO; layer.drawableSize = CGSizeMake(OW,OH);
        Class standIn = NSClassFromString(@"BG3MFXStandInDrawable");
        // Per view: FSR dispatches, RCAS dispatches, RCAS threads in the right half.
        id<MTLBuffer> count = [device newBufferWithLength:32 options:MTLResourceStorageModeShared];
        id<MTLBuffer> afterFirst = [device newBufferWithLength:OW*OH*sizeof(float)*4 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        float camera[56]={}, temporal[56]={};
        camera[21]=1.7320508; camera[48]=0.1; camera[49]=1000;
        camera[26]=-camera[48]/(camera[49]-camera[48]); camera[30]=camera[48]*camera[49]/(camera[49]-camera[48]);
        // BG3's Viewport constants for each view: scale, offset, size, minimum, index.
        float viewports[2][42]={};
        for (int v=0; v<2; ++v) {
            viewports[v][0]=0.5f; viewports[v][1]=1; viewports[v][2]=v*0.5f; viewports[v][3]=0;
            uint32_t size[2]={uint32_t(W/2),uint32_t(H)}; int32_t minimum[2]={int32_t(v*W/2),0}; int32_t index=v;
            memcpy((char *)viewports[v]+16,size,8); memcpy((char *)viewports[v]+24,minimum,8); memcpy((char *)viewports[v]+40,&index,4);
        }
        auto pass=[&](id<MTLCommandBuffer> b, id<MTLTexture> target, id<MTLRenderPipelineState> state, NSArray *sources, int view, BOOL constants) {
            MTLRenderPassDescriptor *p=[MTLRenderPassDescriptor new]; p.colorAttachments[0].texture=target;
            p.colorAttachments[0].loadAction=MTLLoadActionLoad; p.colorAttachments[0].storeAction=MTLStoreActionStore;
            id<MTLRenderCommandEncoder> e=[b renderCommandEncoderWithDescriptor:p];
            [e setViewport:(MTLViewport){double(view*W/2),0,double(W/2),double(H),0,1}];
            for (NSUInteger i=0;i<sources.count;++i) if (sources[i]!=NSNull.null) [e setFragmentTexture:sources[i] atIndex:i];
            if (constants) {
                [e setFragmentBytes:camera length:sizeof(camera) atIndex:11];
                [e setFragmentBytes:temporal length:sizeof(temporal) atIndex:8];
                [e setFragmentBytes:viewports[view] length:sizeof(viewports[view]) atIndex:9];
            }
            [e setRenderPipelineState:state]; [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
        };
        const float viewColor[2][3]={{0.5f,0.75f,1.0f},{1.0f,0.25f,0.5f}};
        for (int frame=0; frame<5; ++frame) {
            // Frame 0 runs Spatial (BG3's TAA kept, +0.25); later frames run Temporal per view.
            bool spatial = frame == 0;
            if (!select(spatial ? 2 : 3) || !setFrameGeneration(fg)) return 7;
            memset(count.contents,0,32);
            id<CAMetalDrawable> drawable = fg ? [layer nextDrawable] : nil;
            if (fg && ![drawable isKindOfClass:standIn]) { fprintf(stderr,"frame %d: Frame Generation did not give BG3 a stand-in drawable\n",frame); return 14; }
            NSUInteger presentedBefore = fg ? presented() : 0;
            id<MTLCommandBuffer> b=[queue commandBufferWithUnretainedReferences];
            // BG3 schedules its present before it encodes CombineUI.
            if (fg) [b presentDrawable:drawable];
            id<MTLComputeCommandEncoder> c=[b computeCommandEncoder];
            [c setComputePipelineState:compute[0]]; [c setTexture:color atIndex:0]; [c setTexture:motion atIndex:1];
            [c dispatchThreads:MTLSizeMake(W,H,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)]; [c endEncoding];
            MTLRenderPassDescriptor *clear=[MTLRenderPassDescriptor new];
            clear.depthAttachment.texture=depth; clear.depthAttachment.loadAction=MTLLoadActionClear;
            clear.depthAttachment.storeAction=MTLStoreActionStore; clear.depthAttachment.clearDepth=0.5;
            [[b renderCommandEncoderWithDescriptor:clear] endEncoding];
            for (int view=0; view<2; ++view) {
                pass(b,linearDepth,render[0],@[depth],view,NO);
                pass(b,motion,render[2],@[],view,YES);
                pass(b,taa,render[1],@[color,NSNull.null,motion],view,YES);
                // In split screen BG3 copies each view's post-processed color into
                // the next pass's input with a blit, as from bloom into colour grading.
                id<MTLBlitCommandEncoder> copy=[b blitCommandEncoder];
                [copy copyFromTexture:taa sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(view*W/2,0,0) sourceSize:MTLSizeMake(W/2,H,1)
                            toTexture:graded destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(view*W/2,0,0)];
                [copy endEncoding];
                pass(b,tonemapped,render[3],@[graded],view,YES);
                c=[b computeCommandEncoder];
                [c setTexture:tonemapped atIndex:0]; [c setTexture:scaled atIndex:1]; [c setComputePipelineState:compute[1]];
                [c setBuffer:count offset:view*16 atIndex:0];
                [c dispatchThreads:MTLSizeMake(OW,OH,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
                [c setTexture:scaled atIndex:0]; [c setTexture:output atIndex:2]; [c setComputePipelineState:compute[2]];
                [c dispatchThreads:MTLSizeMake(OW,OH,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)]; [c endEncoding];
                if (fg) {
                    MTLRenderPassDescriptor *p=[MTLRenderPassDescriptor new]; p.colorAttachments[0].texture=scene;
                    p.colorAttachments[0].loadAction=MTLLoadActionLoad; p.colorAttachments[0].storeAction=MTLStoreActionStore;
                    id<MTLRenderCommandEncoder> e=[b renderCommandEncoderWithDescriptor:p];
                    [e setViewport:(MTLViewport){double(view*OW/2),0,double(OW/2),double(OH),0,1}];
                    [e setFragmentTexture:output atIndex:0]; [e setRenderPipelineState:render[4]];
                    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e endEncoding];
                }
                // BG3 tone-maps each view right after its RCAS: the left view's
                // half must be final before the right view is processed.
                if (view==0) {
                    c=[b computeCommandEncoder]; [c setComputePipelineState:compute[3]];
                    [c setTexture:output atIndex:0]; [c setBuffer:afterFirst offset:0 atIndex:0];
                    [c dispatchThreads:MTLSizeMake(OW,OH,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)]; [c endEncoding];
                }
            }
            c=[b computeCommandEncoder]; [c setComputePipelineState:compute[3]];
            [c setTexture:output atIndex:0]; [c setBuffer:pixels offset:0 atIndex:0];
            [c dispatchThreads:MTLSizeMake(OW,OH,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)]; [c endEncoding];
            NSDictionary *generatedPair = nil;
            if (fg) {
                MTLRenderPassDescriptor *p=[MTLRenderPassDescriptor new]; p.colorAttachments[0].texture=ui;
                p.colorAttachments[0].loadAction=MTLLoadActionClear; p.colorAttachments[0].storeAction=MTLStoreActionStore;
                p.colorAttachments[0].clearColor=MTLClearColorMake(.8,.2,.4,1);
                [[b renderCommandEncoderWithDescriptor:p] endEncoding];
                p=[MTLRenderPassDescriptor new]; p.colorAttachments[0].texture=drawable.texture;
                p.colorAttachments[0].loadAction=MTLLoadActionDontCare; p.colorAttachments[0].storeAction=MTLStoreActionStore;
                id<MTLRenderCommandEncoder> e=[b renderCommandEncoderWithDescriptor:p];
                float tint[4]={1,1,1,1};
                [e setRenderPipelineState:render[5]]; [e setVertexBuffer:vertices offset:0 atIndex:0];
                [e setFragmentBytes:tint length:sizeof(tint) atIndex:0]; [e setFragmentSamplerState:sampler atIndex:0];
                [e setFragmentTexture:scene atIndex:0]; [e setFragmentTexture:ui atIndex:1];
                [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4]; [e endEncoding];
                generatedPair = pair(b);
                if (!generatedPair) { fprintf(stderr,"frame %d: no generated pair for the split-screen frame\n",frame); return 15; }
                id<MTLBlitCommandEncoder> blit=[b blitCommandEncoder];
                id<MTLTexture> images[2]={drawable.texture,generatedPair[@"generated"]};
                for (int i=0;i<2;++i)
                    [blit copyFromTexture:images[i] sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(OW,OH,1)
                                 toBuffer:composites[i] destinationOffset:0 destinationBytesPerRow:OW*4 destinationBytesPerImage:OW*OH*4];
                [blit endEncoding];
            }
            [b commit]; [b waitUntilCompleted];
            if (b.status!=MTLCommandBufferStatusCompleted) { fprintf(stderr,"frame %d failed: %s\n",frame,b.error.description.UTF8String); return 8; }
            const uint32_t *n=(const uint32_t *)count.contents;
            if (n[0]+n[4]!=0 || n[1]+n[5]!=(sharpening ? 2u : 0u)) {
                fprintf(stderr,"frame %d: %u FSR and %u RCAS dispatches\n",frame,n[0]+n[4],n[1]+n[5]); return 9;
            }
            // The left view's RCAS replay covers only its half; the right view's, like BG3's, the frame.
            if (sharpening && (n[2]!=0 || n[6]==0)) {
                fprintf(stderr,"frame %d: RCAS threads in the right half: %u for the left view, %u for the right\n",frame,n[2],n[6]); return 12;
            }
            // Spatial keeps BG3's TAA; Temporal replaces it from its first frame,
            // since Spatial already identified this TAA target as upscaled.
            const float added = spatial ? 0.25f : 0;
            const float *p=(const float *)pixels.contents;
            const float *first=(const float *)afterFirst.contents;
            for (NSUInteger x=0;x<OW/2;++x) for (int ch=0;ch<3;++ch) {
                float actual=first[((OH/2)*OW+x)*4+ch], expected=viewColor[0][ch]+added;
                if ((!std::isfinite(actual) || fabs(actual-expected)>0.08f)) {
                    fprintf(stderr,"%s frame %d: the left view at %lu after its own pass: %f != %f\n",spatial ? "Spatial" : "Temporal",frame,x,actual,expected); return 13;
                }
            }
            // Every column, including the two at the seam, holds only its own view.
            for (NSUInteger x=0;x<OW;++x) for (NSUInteger y=OH/2-8;y<OH/2+8;y+=4) for (int ch=0;ch<3;++ch) {
                float actual=p[(y*OW+x)*4+ch], expected=viewColor[x<OW/2 ? 0 : 1][ch]+added;
                if (!std::isfinite(actual) || fabs(actual-expected)>0.08f) {
                    fprintf(stderr,"%s frame %d pixel %lu,%lu channel %d: %f != %f\n",spatial ? "Spatial" : "Temporal",frame,x,y,ch,actual,expected); return 10;
                }
            }
            if (fg) {
                // A static scene: each half of the generated composite matches the
                // real one, and the halves keep their own colors at the seam.
                const uint8_t *real=(const uint8_t *)composites[0].contents, *generated=(const uint8_t *)composites[1].contents;
                int worst=0;
                for (NSUInteger i=0;i<OW*OH*4;++i) worst=std::max(worst,abs(int(real[i])-int(generated[i])));
                int seam=abs(int(generated[((OH/2)*OW+OW/2-1)*4])-int(generated[((OH/2)*OW+OW/2)*4]));
                if (worst>8 || seam<16) {
                    fprintf(stderr,"%s frame %d: generated composite differs from the real one by %d, %d across the seam\n",spatial ? "Spatial" : "Temporal",frame,worst,seam); return 16;
                }
                for (int i=0;i<200 && presented()==presentedBefore;++i) [NSThread sleepForTimeInterval:.01];
                if (presented()!=presentedBefore+1) { fprintf(stderr,"frame %d: the generated pair was not presented\n",frame); return 17; }
            }
        }
        if (created()!=2) { fprintf(stderr,"%lu Temporal scalers for two split-screen views\n",(unsigned long)created()); return 11; }
        // One interpolator per view for Spatial (frame 0) and again for Temporal.
        if (fg && interpolators()!=4) { fprintf(stderr,"%lu frame interpolators for two views in two modes\n",(unsigned long)interpolators()); return 18; }
        if (fg) {
            puts("Split screen with Frame Generation: Spatial and Temporal upscaled and interpolated each view on its own (an interpolator per view), and the generated frame composed like the real one, halves intact at the seam.");
            return 0;
        }
        puts(sharpening ? "Split screen: Spatial and Temporal upscaled each view on its own, one Temporal scaler per view, no blending at the seam, and BG3's RCAS sharpened each view's pass."
                        : "Split screen: Spatial and Temporal upscaled each view on its own, one Temporal scaler per view, and no blending at the seam (sharpening off).");
    }
    return 0;
}
