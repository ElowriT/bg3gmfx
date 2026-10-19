#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <cmath>
#include <cstring>

// Split screen: BG3 renders two views side by side into shared textures (each
// pass with its view's viewport and Viewport constants), then runs FSR and RCAS
// over the whole frame once per view. MetalFX Spatial and Temporal must upscale
// each view on its own (Temporal with a scaler, and so a history, per view),
// write only that view's half, and never blend the two halves at the seam.
static id<MTLTexture> texture(id<MTLDevice> device, NSUInteger width, NSUInteger height, MTLPixelFormat format, MTLTextureUsage usage) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
    d.storageMode = MTLStorageModePrivate; d.usage = usage;
    return [device newTextureWithDescriptor:d];
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) return 1;
        setenv("BG3MFX_ENABLE_METALFX","1",1);
        void *runtime = dlopen(argv[1],RTLD_NOW | RTLD_LOCAL);
        if (!runtime) { fprintf(stderr,"%s\n",dlerror()); return 2; }
        auto select = (BOOL(*)(int))dlsym(runtime,"BG3MFXSetStandaloneScalingMode");
        auto created = (NSUInteger(*)(void))dlsym(runtime,"BG3MFXStandaloneTemporalScalersCreated");
        if (!select || !created) return 3;
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
            // Two views: the left half one color, the right half another.
            "kernel void Fill(texture2d<float,access::write> color [[texture(0)]], texture2d<float,access::write> motion [[texture(1)]], uint2 p [[thread_position_in_grid]]) {"
            "color.write(p.x < color.get_width()/2 ? float4(0.5,0.75,1.0,1) : float4(1.0,0.25,0.5,1),p);motion.write(float4(0),p);}\n"
            "kernel void FSR(texture2d<float,access::read> src [[texture(0)]], texture2d<float,access::write> dst [[texture(1)]], device atomic_uint *count [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {"
            "if(all(p==uint2(0))) atomic_fetch_add_explicit(count,1,memory_order_relaxed);dst.write(src.read(p/2),p);}\n"
            "kernel void FSR_RCAS(texture2d<float,access::read> src [[texture(0)]], texture2d<float,access::write> dst [[texture(2)]], device atomic_uint *count [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {"
            "if(all(p==uint2(0))) atomic_fetch_add_explicit(count+1,1,memory_order_relaxed);float3 c=src.read(p).rgb;dst.write(float4(c/(1-max(c.r,max(c.g,c.b))),1),p);}\n"
            "kernel void Read(texture2d<float,access::read> src [[texture(0)]], device float4 *out [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {out[p.y*src.get_width()+p.x]=src.read(p);}";
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        if (!library) { fprintf(stderr,"%s\n",error.description.UTF8String); return 4; }
        NSMutableArray *compute = [NSMutableArray array];
        for (NSString *name in @[@"Fill",@"FSR",@"FSR_RCAS",@"Read"]) {
            id state = [device newComputePipelineStateWithFunction:[library newFunctionWithName:name] error:&error];
            if (!state) return 5; [compute addObject:state];
        }
        NSMutableArray *render = [NSMutableArray array];
        for (NSString *name in @[@"LinearizeDepth",@"PPTAA_PS",@"VelocityBufferCamera_PS",@"FSR_Tonemap"]) {
            MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
            d.vertexFunction = [library newFunctionWithName:@"Fullscreen"]; d.fragmentFunction = [library newFunctionWithName:name];
            d.colorAttachments[0].pixelFormat = [name isEqualToString:@"LinearizeDepth"] ? MTLPixelFormatR32Float : [name isEqualToString:@"VelocityBufferCamera_PS"] ? MTLPixelFormatRG16Float : MTLPixelFormatRG11B10Float;
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
        id<MTLTexture> scaled = texture(device,OW,OH,MTLPixelFormatRGBA16Float,rw);
        id<MTLTexture> output = texture(device,OW,OH,MTLPixelFormatRG11B10Float,rw);
        id<MTLBuffer> pixels = [device newBufferWithLength:OW*OH*sizeof(float)*4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> count = [device newBufferWithLength:8 options:MTLResourceStorageModeShared];
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
            if (!select(spatial ? 2 : 3)) return 7;
            memset(count.contents,0,8);
            id<MTLCommandBuffer> b=[queue commandBufferWithUnretainedReferences];
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
                pass(b,tonemapped,render[3],@[taa],view,YES);
                c=[b computeCommandEncoder];
                [c setTexture:tonemapped atIndex:0]; [c setTexture:scaled atIndex:1]; [c setComputePipelineState:compute[1]];
                [c setBuffer:count offset:0 atIndex:0];
                [c dispatchThreads:MTLSizeMake(OW,OH,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
                [c setTexture:scaled atIndex:0]; [c setTexture:output atIndex:2]; [c setComputePipelineState:compute[2]];
                [c dispatchThreads:MTLSizeMake(OW,OH,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)]; [c endEncoding];
            }
            c=[b computeCommandEncoder]; [c setComputePipelineState:compute[3]];
            [c setTexture:output atIndex:0]; [c setBuffer:pixels offset:0 atIndex:0];
            [c dispatchThreads:MTLSizeMake(OW,OH,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)]; [c endEncoding];
            [b commit]; [b waitUntilCompleted];
            if (b.status!=MTLCommandBufferStatusCompleted) { fprintf(stderr,"frame %d failed: %s\n",frame,b.error.description.UTF8String); return 8; }
            const uint32_t *n=(const uint32_t *)count.contents;
            if (n[0]!=0 || n[1]!=(sharpening ? 2u : 0u)) { fprintf(stderr,"frame %d: %u FSR and %u RCAS dispatches\n",frame,n[0],n[1]); return 9; }
            // Spatial keeps BG3's TAA; Temporal replaces it from its first frame,
            // since Spatial already identified this TAA target as upscaled.
            const float added = spatial ? 0.25f : 0;
            const float *p=(const float *)pixels.contents;
            // Every column, including the two at the seam, holds only its own view.
            for (NSUInteger x=0;x<OW;++x) for (NSUInteger y=OH/2-8;y<OH/2+8;y+=4) for (int ch=0;ch<3;++ch) {
                float actual=p[(y*OW+x)*4+ch], expected=viewColor[x<OW/2 ? 0 : 1][ch]+added;
                if (!std::isfinite(actual) || fabs(actual-expected)>0.08f) {
                    fprintf(stderr,"%s frame %d pixel %lu,%lu channel %d: %f != %f\n",spatial ? "Spatial" : "Temporal",frame,x,y,ch,actual,expected); return 10;
                }
            }
        }
        if (created()!=2) { fprintf(stderr,"%lu Temporal scalers for two split-screen views\n",(unsigned long)created()); return 11; }
        puts(sharpening ? "Split screen: Spatial and Temporal upscaled each view on its own, one Temporal scaler per view, no blending at the seam, and BG3's RCAS sharpened each view's pass."
                        : "Split screen: Spatial and Temporal upscaled each view on its own, one Temporal scaler per view, and no blending at the seam (sharpening off).");
    }
    return 0;
}
