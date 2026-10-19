#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <GameController/GameController.h>
#include <objc/runtime.h>
#include <dlfcn.h>
#include <unistd.h>

// Lab mode: control.txt skip rules drop matching draws and dispatches, and a
// census records one frame's passes. A full-screen "fog" draw over a "keep"
// draw stands in for the shader under investigation.
static NSString *directory;
static void control(NSString *text) {
    [text writeToFile:[directory stringByAppendingPathComponent:@"control.txt"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
    usleep(300000); // the runtime rereads the file at most four times a second
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        char path[] = "/tmp/bg3mfx-lab-XXXXXX";
        if (!mkdtemp(path)) return 3;
        directory = [NSString stringWithUTF8String:path];
        setenv("BG3MFX_LAB",path,1);
        if (!dlopen(argv[1], RTLD_NOW)) { fprintf(stderr, "%s\n", dlerror()); return 1; }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSError *error = nil;
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "vertex float4 labVS(uint id [[vertex_id]]) { float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[id],0,1); }\n"
            "fragment float4 LabSmokeKeep() { return float4(0,1,0,1); }\n"
            "fragment float4 LabFogSmoke(constant float4 &tint [[buffer(3)]]) { return tint; }\n"
            "fragment float4 LabTintAfter(constant float4 &tint [[buffer(3)]]) { return tint; }\n"
            "kernel void LabFogSmokeKernel(device uint *dst [[buffer(0)]], uint p [[thread_position_in_grid]]) { dst[p] += 1; }\n"
            "kernel void LabPokeKernel(constant float *v [[buffer(1)]], device float *out [[buffer(2)]]) { out[0] = v[1]; }\n"
            "kernel void LabReadKernel(constant float *v [[buffer(1)]], device float *out [[buffer(2)]]) { out[1] = v[1]; }\n"
            "kernel void LabStampKernel(device uint *s [[buffer(5)]], constant uint &v [[buffer(6)]]) { s[0] = v; }\n";
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        if (!library) { fprintf(stderr,"%s\n",error.description.UTF8String); return 4; }
        NSMutableArray<id<MTLRenderPipelineState>> *pipelines = [NSMutableArray array];
        NSString *fragments[3] = {@"LabSmokeKeep",@"LabFogSmoke",@"LabTintAfter"};
        for (int i = 0; i < 3; ++i) {
            MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
            desc.vertexFunction = [library newFunctionWithName:@"labVS"];
            desc.fragmentFunction = [library newFunctionWithName:fragments[i]];
            desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
            // A vertex layout for the census to report; labVS itself reads no attributes.
            desc.vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
            desc.vertexDescriptor.attributes[1].format = MTLVertexFormatFloat2;
            desc.vertexDescriptor.attributes[1].offset = 8;
            desc.vertexDescriptor.layouts[0].stride = 16;
            id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:desc error:&error];
            if (!state) return 5;
            [pipelines addObject:state];
        }
        id<MTLComputePipelineState> kernel = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"LabFogSmokeKernel"] error:&error];
        if (!kernel) return 6;
        id<MTLComputePipelineState> pokeKernel = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"LabPokeKernel"] error:&error];
        id<MTLComputePipelineState> readKernel = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"LabReadKernel"] error:&error];
        id<MTLComputePipelineState> stampKernel = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"LabStampKernel"] error:&error];
        if (!pokeKernel || !readKernel || !stampKernel) return 7;
        id<MTLBuffer> stamp = [device newBufferWithLength:4 options:MTLResourceStorageModeShared];
        const float values[4] = {1,2,3,4};
        id<MTLBuffer> constants = [device newBufferWithBytes:values length:sizeof(values) options:MTLResourceStorageModeShared];
        id<MTLBuffer> results = [device newBufferWithLength:8 options:MTLResourceStorageModeShared];
        MTLTextureDescriptor *textureDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
        textureDesc.usage = MTLTextureUsageRenderTarget; textureDesc.storageMode = MTLStorageModeShared;
        id<MTLTexture> target = [device newTextureWithDescriptor:textureDesc];
        target.label = @"LabTarget";
        id<MTLTexture> sample = [device newTextureWithDescriptor:[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:2 height:2 mipmapped:NO]];
        id<MTLBuffer> counter = [device newBufferWithLength:4 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.device = device; layer.pixelFormat = MTLPixelFormatBGRA8Unorm; layer.drawableSize = CGSizeMake(8,8);
        // One frame: present first, as BG3 does before its last passes, so the
        // control file is applied before this frame's pipelines are bound.
        auto frame = ^uint32_t {
            id<CAMetalDrawable> drawable = [layer nextDrawable];
            id<MTLCommandBuffer> buffer = [queue commandBuffer];
            [buffer presentDrawable:drawable];
            id<MTLComputeCommandEncoder> compute = [buffer computeCommandEncoder];
            [compute setComputePipelineState:kernel]; [compute setBuffer:counter offset:0 atIndex:0];
            [compute dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
            // A poked dispatch, then one that must see the original binding again.
            [compute setBuffer:constants offset:0 atIndex:1]; [compute setBuffer:results offset:0 atIndex:2];
            [compute setComputePipelineState:pokeKernel];
            [compute dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
            [compute setComputePipelineState:readKernel];
            [compute dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
            // Two stamps: dumps pick an occurrence and copy when the encoder ends.
            [compute setComputePipelineState:stampKernel]; [compute setBuffer:stamp offset:0 atIndex:5];
            for (uint32_t v = 1; v <= 2; ++v) {
                [compute setBytes:&v length:4 atIndex:6];
                [compute dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
            }
            [compute endEncoding];
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
            pass.colorAttachments[0].texture = target;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> render = [buffer renderCommandEncoderWithDescriptor:pass];
            render.label = @"LabScene";
            [render setViewport:(MTLViewport){0,0,4,8,0,1}];
            const float quad[4] = {0.25f,0.5f,0.75f,1.0f};
            [render setVertexBytes:quad length:sizeof(quad) atIndex:0];
            [render setFragmentTexture:sample atIndex:0];
            const float tint[4] = {1,0,0,1};
            [render setFragmentBytes:tint length:sizeof(tint) atIndex:3];
            for (int i = 0; i < 3; ++i) {
                if (i == 2) [render setViewport:(MTLViewport){4,0,4,8,0,1}];  // the right half reads the same tint
                [render setRenderPipelineState:pipelines[i]];
                [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            }
            [render endEncoding];
            id<MTLBlitCommandEncoder> wipe = [buffer blitCommandEncoder];
            [wipe fillBuffer:stamp range:NSMakeRange(0,4) value:0xEE];
            [wipe endEncoding];
            [buffer commit]; [buffer waitUntilCompleted];
            uint32_t pixel = 0;
            [target getBytes:&pixel bytesPerRow:32 fromRegion:MTLRegionMake2D(1,4,1,1) mipmapLevel:0];
            return pixel;
        };
        const uint32_t red = 0xff0000ff, green = 0xff00ff00;
        if (frame() != red) { fprintf(stderr,"Without rules the fog draw should cover the scene\n"); return 10; }
        control(@"skip FogSmoke\n");
        uint32_t before = *(uint32_t *)counter.contents;
        if (frame() != green) { fprintf(stderr,"The fog draw was not skipped\n"); return 11; }
        if (*(uint32_t *)counter.contents != before) { fprintf(stderr,"The fog dispatch was not skipped\n"); return 12; }
        control(@"skip FogSmoke\nwatch SmokeKeep\ncensus first\n");
        frame(); frame();
        NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"census-first.json"]];
        NSDictionary *census = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *scene = nil, *dispatch = nil;
        for (NSDictionary *entry in census[@"encoders"]) {
            if ([entry[@"label"] isEqualToString:@"LabScene"]) scene = entry;
            if ([entry[@"kind"] isEqualToString:@"compute"]) dispatch = entry;
        }
        if (!scene || [scene[@"draws"][@"labVS|LabSmokeKeep"] intValue] != 1 ||
            [scene[@"draws"][@"labVS|LabFogSmoke [skipped]"] intValue] != 1 ||
            ![scene[@"colors"][0][@"label"] isEqualToString:@"LabTarget"] ||
            [dispatch[@"dispatches"][@"LabFogSmokeKernel [skipped]"] intValue] != 1 ||
            ![dispatch[@"grids"][@"LabFogSmokeKernel [skipped]"] isEqualToString:@"threads 1x1x1 / 1x1x1"] ||
            [scene[@"watched"] count] != 1 || ![scene[@"watched"][0][@"shader"] isEqualToString:@"labVS|LabSmokeKeep"] ||
            [scene[@"viewport"][2] intValue] != 4 || [scene[@"watched"][0][@"viewport"][2] intValue] != 4 ||
            [scene[@"watched"][0][@"textures"][@"0"][@"width"] intValue] != 2 ||
            [[[NSData alloc] initWithBase64EncodedString:scene[@"watched"][0][@"buffers"][@"vertex:0"][@"base64"] options:0] length] != 16 ||
            ![scene[@"setBytes"][0][@"slot"] isEqualToString:@"vertex:0"] || [scene[@"setBytes"][0][@"length"] intValue] != 16 ||
            [census[@"vertexLayouts"][@"labVS|LabSmokeKeep"][@"attributes"][0][@"offset"] intValue] != 8 ||
            [census[@"vertexLayouts"][@"labVS|LabSmokeKeep"][@"layouts"][0][@"stride"] intValue] != 16 ||
            census[@"vertexLayouts"][@"labVS|LabFogSmoke"]) {
            fprintf(stderr,"The census did not record the frame's passes: %s\n",census.description.UTF8String); return 13;
        }
        control(@"poke LabPokeKernel 1 4 7\nwatch LabPokeKernel\ncensus second\n");
        frame(); frame();
        const float *out = (const float *)results.contents;
        if (out[0] != 7 || out[1] != 2) { fprintf(stderr,"Poke wrote %g and the next dispatch read %g (expected 7, 2)\n",out[0],out[1]); return 16; }
        NSData *secondData = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"census-second.json"]];
        NSDictionary *second = secondData ? [NSJSONSerialization JSONObjectWithData:secondData options:0 error:nil] : nil;
        NSString *recorded = nil;
        for (NSDictionary *entry in second[@"encoders"]) for (NSDictionary *call in entry[@"watched"])
            if ([call[@"shader"] isEqualToString:@"LabPokeKernel"]) recorded = call[@"buffers"][@"compute:1"][@"base64"];
        NSData *bytes = recorded ? [[NSData alloc] initWithBase64EncodedString:recorded options:0] : nil;
        if (bytes.length < 8 || ((const float *)bytes.bytes)[1] != 2) { fprintf(stderr,"The watched dispatch did not record its constant buffer\n"); return 17; }
        const uint8_t texels[4] = {10,20,30,40};
        [sample replaceRegion:MTLRegionMake2D(0,0,2,2) mipmapLevel:0 withBytes:texels bytesPerRow:2];
        control(@"dump keep SmokeKeep 0\n");
        frame(); frame();
        NSData *dumped = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"dump-keep.raw"]];
        if (dumped.length != 4 || memcmp(dumped.bytes,texels,4)) { fprintf(stderr,"The dump did not copy the bound texture\n"); return 19; }
        control(@"dumpbuf vals LabPokeKernel 1 16\n");
        frame(); frame();
        NSData *dumpedValues = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"dump-vals.raw"]];
        if (dumpedValues.length != 16 || ((const float *)dumpedValues.bytes)[1] != 2) { fprintf(stderr,"The buffer dump did not copy the bound constants\n"); return 20; }
        control(@"dumpbuf stamp LabStampKernel 5 4\ndumpbuf second LabStampKernel 6 4 #2\ndumpbuf quad SmokeKeep vertex:0 16\n"
            "dump col labVS color0 #2\npoke LabFogSmoke fragment:3 0 0\npoke LabFogSmoke fragment:3 8 1\n");
        uint32_t poked = frame(); frame();
        uint32_t right = 0;
        [target getBytes:&right bytesPerRow:32 fromRegion:MTLRegionMake2D(5,4,1,1) mipmapLevel:0];
        if (poked != 0xffff0000 || right != red) { fprintf(stderr,"Fragment poke gave %08x and the next draw %08x\n",poked,right); return 21; }
        auto file = ^NSData *(NSString *tag) { return [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"dump-%@.raw",tag]]]; };
        NSData *stampData = file(@"stamp"), *secondStamp = file(@"second"), *quadData = file(@"quad"), *color = file(@"col");
        if (stampData.length != 4 || *(const uint32_t *)stampData.bytes != 2 || secondStamp.length != 4 || *(const uint32_t *)secondStamp.bytes != 2 ||
            quadData.length != 16 || ((const float *)quadData.bytes)[3] != 1.0f || color.length != 256 || ((const uint32_t *)color.bytes)[4*8+1] != 0xffff0000) {
            fprintf(stderr,"End-of-encoder dumps: stamp %u, #2 bytes %u, quad %lu bytes, color %lu bytes\n",
                stampData.length == 4 ? *(const uint32_t *)stampData.bytes : 0, secondStamp.length == 4 ? *(const uint32_t *)secondStamp.bytes : 0,
                (unsigned long)quadData.length,(unsigned long)color.length); return 22;
        }
        // A profile times every pass of one frame with GPU timestamps.
        control(@"profile prof\n");
        frame(); frame(); frame();
        usleep(800000);
        NSData *profileData = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"profile-prof.json"]];
        NSDictionary *profile = profileData ? [NSJSONSerialization JSONObjectWithData:profileData options:0 error:nil] : nil;
        bool timedScene = false, timedCompute = false;
        for (NSDictionary *pass in profile[@"passes"]) {
            double ms = [pass[@"gpuMs"] doubleValue];
            if (ms < 0 || ms > 1000) { fprintf(stderr,"Implausible pass time %f\n",ms); return 23; }
            if ([pass[@"label"] isEqualToString:@"LabScene"]) timedScene = true;
            if ([pass[@"kind"] isEqualToString:@"compute"]) timedCompute = true;
        }
        if (!timedScene || !timedCompute) { fprintf(stderr,"The profile did not time the frame's passes: %s\n",profile.description.UTF8String); return 24; }
        // Virtual controllers: "pad N" lines connect them and name held buttons
        // and stick positions; a pad without a line disconnects.
        // Physical controllers connected to the Mac are left out of the counts.
        auto virtualPad = ^bool(id controller) { return !strcmp(object_getClassName(controller),"BG3MFXLabController"); };
        auto virtualPads = ^NSUInteger { NSUInteger n = 0; for (GCController *c in GCController.controllers) n += virtualPad(c); return n; };
        __block NSUInteger connects = 0, disconnects = 0;
        [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification object:nil queue:nil
            usingBlock:^(NSNotification *note) { connects += virtualPad(note.object); }];
        [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidDisconnectNotification object:nil queue:nil
            usingBlock:^(NSNotification *note) { disconnects += virtualPad(note.object); }];
        auto settle = ^{ frame(); [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]]; };
        control(@"pad 1\npad 2 a lb up\npad 2 stick left 0.5 -1\n");
        settle();
        GCController *joined = nil;
        for (GCController *controller in GCController.controllers) if (virtualPad(controller) && controller.extendedGamepad.buttonA.pressed) joined = controller;
        GCExtendedGamepad *gamepad = joined.extendedGamepad;
        if (connects != 2 || virtualPads() != 2 || !joined ||
            ![joined.vendorName isEqualToString:@"Xbox Wireless Controller"]) {
            fprintf(stderr,"Two virtual controllers did not connect (%lu notifications): %s\n",(unsigned long)connects,
                [NSString stringWithContentsOfFile:[directory stringByAppendingPathComponent:@"status.json"] encoding:NSUTF8StringEncoding error:nil].UTF8String); return 25;
        }
        if (!gamepad.leftShoulder.pressed || gamepad.buttonB.pressed || gamepad.dpad.yAxis.value != 1 ||
            gamepad.leftThumbstick.xAxis.value != 0.5f || gamepad.leftThumbstick.yAxis.value != -1) {
            fprintf(stderr,"The virtual controller does not hold the named buttons and stick position\n"); return 26;
        }
        __block NSUInteger changes = 0, pauses = 0;
        gamepad.valueChangedHandler = ^(GCExtendedGamepad *, GCControllerElement *) { ++changes; };
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        joined.controllerPausedHandler = ^(GCController *) { ++pauses; };
#pragma clang diagnostic pop
        control(@"pad 1\npad 2 b menu\n");
        settle();
        if (gamepad.buttonA.pressed || !gamepad.buttonB.pressed || gamepad.dpad.yAxis.value != 0 || gamepad.leftThumbstick.xAxis.value != 0 || !changes) {
            fprintf(stderr,"Changing the pad lines did not update the controller (%lu change callbacks)\n",(unsigned long)changes); return 27;
        }
        if (pauses != 1) { fprintf(stderr,"Pressing Menu called the pause handler %lu times\n",(unsigned long)pauses); return 30; }
        control(@"pad 2 b\n");
        settle(); settle();
        NSData *padStatusData = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"status.json"]];
        NSDictionary *padStatus = padStatusData ? [NSJSONSerialization JSONObjectWithData:padStatusData options:0 error:nil] : nil;
        if (disconnects != 1 || virtualPads() != 1 || ![joined.vendorName length]) {
            fprintf(stderr,"Removing a pad's lines did not disconnect it\n"); return 28;
        }
        if (![padStatus[@"pads"] isKindOfClass:NSArray.class]) { fprintf(stderr,"status.json does not report the pads\n"); return 29; }
        control(@"serialize\n");
        if (frame() != red || frame() != red) { fprintf(stderr,"Serialized encoders changed the frame\n"); return 18; }
        control(@"");
        if (frame() != red) { fprintf(stderr,"Clearing the rules did not restore the fog draw\n"); return 14; }
        NSData *statusData = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"status.json"]];
        NSDictionary *status = statusData ? [NSJSONSerialization JSONObjectWithData:statusData options:0 error:nil] : nil;
        if ([status[@"skip"] count] != 0) { fprintf(stderr,"status.json does not report the cleared rules\n"); return 15; }
        [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
        printf("Lab mode skipped a named draw and dispatch, recorded a one-frame census, poked and restored a compute constant, drove two virtual controllers, and restored them.\n");
    }
    return 0;
}
