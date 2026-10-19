// Print Metal reflection for functions in a game metallib: every binding with
// its index, access and type, and buffer struct members by name and offset.
// usage: metallib_reflect <file.metallib> <kernel>... [--render <vertex> <fragment> <pixelFormat>]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

static void members(MTLStructType *type, NSString *indent, NSUInteger depth) {
    for (MTLStructMember *m in type.members) {
        printf("%s%4lu %s (type %lu", indent.UTF8String, (unsigned long)m.offset, m.name.UTF8String, (unsigned long)m.dataType);
        if (m.dataType == MTLDataTypeArray) printf(", array %lu of %lu", (unsigned long)m.arrayType.arrayLength, (unsigned long)m.arrayType.elementType);
        printf(")\n");
        if (m.dataType == MTLDataTypeStruct && depth < 3) members(m.structType,[indent stringByAppendingString:@"  "],depth+1);
        if (m.dataType == MTLDataTypeArray && m.arrayType.elementType == MTLDataTypeStruct && depth < 3)
            members(m.arrayType.elementStructType,[indent stringByAppendingString:@"  "],depth+1);
    }
}
static void bindings(NSArray<id<MTLBinding>> *list, const char *stage) {
    static const char *access[] = {"read", "read_write", "write"};
    for (id<MTLBinding> b in [list sortedArrayUsingComparator:^NSComparisonResult(id<MTLBinding> a, id<MTLBinding> c) {
            return a.type != c.type ? (a.type < c.type ? NSOrderedAscending : NSOrderedDescending) : (a.index < c.index ? NSOrderedAscending : a.index > c.index ? NSOrderedDescending : NSOrderedSame); }]) {
        const char *kind = b.type == MTLBindingTypeBuffer ? "buffer" : b.type == MTLBindingTypeTexture ? "texture" :
            b.type == MTLBindingTypeSampler ? "sampler" : "other";
        printf("  %s %s %lu %s [%s]%s", stage, kind, (unsigned long)b.index, b.name.UTF8String,
            b.access <= 2 ? access[b.access] : "?", b.used ? "" : " (unused)");
        if (b.type == MTLBindingTypeTexture) printf(" textureType %lu", (unsigned long)((id<MTLTextureBinding>)b).textureType);
        if (b.type == MTLBindingTypeBuffer) {
            id<MTLBufferBinding> buffer = (id<MTLBufferBinding>)b;
            printf(" size %lu\n", (unsigned long)buffer.bufferDataSize);
            if (buffer.bufferStructType) members(buffer.bufferStructType,@"      ",0);
        } else printf("\n");
    }
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr,"usage: %s file.metallib kernel... [--render vertex fragment pixelFormat]\n",argv[0]); return 2; }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&error];
        if (!library) { fprintf(stderr,"%s\n",error.description.UTF8String); return 3; }
        for (int i = 2; i < argc; ++i) {
            if (!strcmp(argv[i],"--render") && i + 3 < argc) {
                MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
                desc.vertexFunction = [library newFunctionWithName:@(argv[i+1])];
                desc.fragmentFunction = [library newFunctionWithName:@(argv[i+2])];
                desc.colorAttachments[0].pixelFormat = (MTLPixelFormat)atoi(argv[i+3]);
                // Fullscreen-pass vertex functions read float2 attributes; give each one a slot.
                desc.vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
                for (NSUInteger a = 0; a < 4; ++a) {
                    desc.vertexDescriptor.attributes[a].format = MTLVertexFormatFloat2;
                    desc.vertexDescriptor.attributes[a].offset = 8*a;
                }
                desc.vertexDescriptor.layouts[0].stride = 32;
                MTLRenderPipelineReflection *reflection = nil;
                id state = [device newRenderPipelineStateWithDescriptor:desc options:MTLPipelineOptionBindingInfo|MTLPipelineOptionBufferTypeInfo
                    reflection:&reflection error:&error];
                printf("== render %s | %s%s\n",argv[i+1],argv[i+2],state ? "" : " (failed)");
                if (!state) printf("  %s\n",error.localizedDescription.UTF8String);
                bindings(reflection.vertexBindings,"vertex");
                bindings(reflection.fragmentBindings,"fragment");
                i += 3; continue;
            }
            id<MTLFunction> function = [library newFunctionWithName:@(argv[i])];
            if (!function) { printf("== %s: not found\n",argv[i]); continue; }
            MTLComputePipelineReflection *reflection = nil;
            id state = [device newComputePipelineStateWithFunction:function options:MTLPipelineOptionBindingInfo|MTLPipelineOptionBufferTypeInfo
                reflection:&reflection error:&error];
            printf("== kernel %s%s\n",argv[i],state ? "" : " (failed)");
            if (!state) { printf("  %s\n",error.localizedDescription.UTF8String); continue; }
            bindings(reflection.bindings,"kernel");
        }
    }
    return 0;
}
