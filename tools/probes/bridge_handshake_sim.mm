#import "common/gpu/GPUResources.h"
#import <QuartzCore/QuartzCore.h>
#include <cstdio>
#include <cstring>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

// Synthetic BG3 <-> Metal 4 bridge handshakes. Plain Metal 3 command buffers
// stand in for BG3's; the bridge is the runtime's own BG3MFXMetal4Bridge. Each
// scenario varies bridge recreation (a quality change creates a new upscaler
// and bridge), commit order, late commits and abandoned buffers, then reports
// when each buffer completed, whether each Metal 4 submission ran between its
// buffer's earlier and later work, and which bridge reported a GPU error.
// Buffers are tracked, enqueued and committed as the runtime does;
// BG3MFX_METAL4_ORDER=0 submits at once instead.
// Usage: bridge-handshake-sim [scenario ...]   (no arguments: list scenarios)

static id<MTLDevice> device;
static double start;
static double now() { return CACurrentMediaTime() - start; }

struct Failure { std::string bridge; double time; std::string error; };
static std::mutex failuresMutex;
static std::vector<Failure> failures;

static BG3MFXMetal4Bridge *makeBridge(const char *name) {
    NSError *error = nil;
    BG3MFXMetal4Bridge *bridge = [[BG3MFXMetal4Bridge alloc] initWithDevice:device
        label:[NSString stringWithUTF8String:name] error:&error];
    if (!bridge) { fprintf(stderr, "bridge %s: %s\n", name, error.description.UTF8String); exit(2); }
    return bridge;
}

// One stand-in BG3 frame: work before the bridge, the bridged Metal 4
// submission(s), and work after it that waits for the Metal 4 result.
struct Frame {
    std::string name;
    id<MTLCommandBuffer> buffer;
    id<MTLBuffer> data;
    // What each bridged submission read from `data`: 1s (the work before it)
    // or, after the first, 3s (the previous submission's) if it ran in order;
    // 2s if it ran after the work after it.
    id<MTLBuffer> seen;
    size_t bridges = 0;
    double committed = -1;
    __block double completed;
    __block long status;
};

static Frame *encodeFrame(id<MTLCommandQueue> queue, const char *name,
                          std::vector<std::pair<BG3MFXMetal4Bridge *, const char *>> bridges) {
    auto frame = new Frame();
    frame->name = name; frame->completed = -1; frame->status = -1;
    frame->buffer = [queue commandBuffer];
    BG3MFXMetal4TrackBuffer(frame->buffer);
    frame->buffer.label = [NSString stringWithUTF8String:name];
    frame->data = [device newBufferWithLength:1 << 20 options:MTLResourceStorageModePrivate];
    frame->bridges = bridges.size();
    frame->seen = [device newBufferWithLength:4 * bridges.size() options:MTLResourceStorageModeShared];
    memset(frame->seen.contents, 0xff, frame->seen.length);
    id<MTLBlitCommandEncoder> before = [frame->buffer blitCommandEncoder];
    [before fillBuffer:frame->data range:NSMakeRange(0, frame->data.length) value:1]; [before endEncoding];
    for (size_t index = 0; index < bridges.size(); ++index) {
        auto &entry = bridges[index];
        std::string label = entry.second;
        id<MTLBuffer> data = frame->data, seen = frame->seen;
        NSError *error = nil;
        BOOL encoded = [entry.first encodeIntoBuffer:frame->buffer allocations:@[frame->data, frame->seen] retained:@[]
            encode:^(id<MTL4CommandBuffer> commands) {
                // Real GPU work on the stand-in's data, like MetalFX on BG3's targets.
                commands.label = @"sim Metal 4 work";
                id<MTL4ComputeCommandEncoder> work = [commands computeCommandEncoder];
                [work copyFromBuffer:data sourceOffset:0 toBuffer:seen destinationOffset:4 * index size:4];
                [work barrierAfterEncoderStages:MTLStageBlit beforeEncoderStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];
                [work fillBuffer:data range:NSMakeRange(0, data.length) value:3]; [work endEncoding];
            }
            failure:^(NSError *gpuError) {
                std::lock_guard<std::mutex> lock(failuresMutex);
                failures.push_back({label, now(), gpuError.localizedDescription.UTF8String ?: ""});
            } error:&error];
        if (!encoded) { fprintf(stderr, "encode %s via %s: %s\n", name, label.c_str(), error.description.UTF8String); exit(3); }
    }
    id<MTLBlitCommandEncoder> after = [frame->buffer blitCommandEncoder];
    [after fillBuffer:frame->data range:NSMakeRange(0, frame->data.length) value:2]; [after endEncoding];
    Frame *captured = frame;
    [frame->buffer addCompletedHandler:^(id<MTLCommandBuffer> done) {
        captured->status = done.status; captured->completed = now();
    }];
    return frame;
}

static void commit(Frame *frame) {
    frame->committed = now();
    id<MTLCommandBuffer> buffer = frame->buffer;
    BG3MFXMetal4Commit(buffer, ^{ [buffer commit]; });
}
static void enqueue(Frame *frame) {
    id<MTLCommandBuffer> buffer = frame->buffer;
    BG3MFXMetal4Enqueue(buffer, ^{ [buffer enqueue]; });
}
static void commitAfter(Frame *frame, double seconds) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ commit(frame); });
}

// Waits for every committed (or scheduled-to-commit) frame, then lets late
// bridge failures arrive, and prints the timeline.
static bool report(const char *scenario, std::vector<Frame *> frames, std::vector<Frame *> abandoned = {},
                   double settle = 11) {
    // Settles past a 4 s queue timeout plus the stall hook's 5 s report delay.
    double deadline = now() + 12;
    for (Frame *frame : frames) while (frame->completed < 0 && now() < deadline) usleep(2000);
    double quiet = now() + settle;
    while (now() < quiet) usleep(10000);
    printf("\n== %s\n", scenario);
    bool stalled = false, misordered = false;
    for (Frame *frame : frames) {
        double latency = frame->completed >= 0 && frame->committed >= 0 ? frame->completed - frame->committed : -1;
        const char *state = frame->completed < 0 ? "NEVER COMPLETED (>12 s)" :
            frame->status == MTLCommandBufferStatusCompleted ? "completed" : "ERROR";
        std::string order;
        for (size_t index = 0; index < frame->bridges && frame->status == MTLCommandBufferStatusCompleted; ++index) {
            uint32_t value = ((const uint32_t *)frame->seen.contents)[index];
            if (value == (index ? 0x03030303u : 0x01010101u)) continue;
            order += value == 0x02020202 ? "  Metal 4 work ran AFTER this buffer's later work" :
                                           "  Metal 4 work ran BEFORE this buffer's earlier work";
            misordered = true;
        }
        printf("  %-10s committed %6.3f s  completed %6.3f s  commit->complete %6.3f s  %s%s\n", frame->name.c_str(),
            frame->committed, frame->completed, latency, state, order.c_str());
        if (frame->completed < 0 || latency > 0.5 || frame->status != MTLCommandBufferStatusCompleted) stalled = true;
    }
    for (Frame *frame : abandoned) printf("  %-10s never committed (abandoned)\n", frame->name.c_str());
    std::lock_guard<std::mutex> lock(failuresMutex);
    for (auto &failure : failures)
        printf("  bridge %-8s reported at %6.3f s: %s\n", failure.bridge.c_str(), failure.time, failure.error.c_str());
    printf("  verdict: %s%s%s\n", stalled ? "STALL" : "no stall", misordered ? ", MISORDERED" : "",
        failures.empty() ? "" : ", bridge error (would show the MetalFX alert)");
    failures.clear();
    return stalled;
}

struct Scenario { const char *name; const char *description; std::function<void()> run; };

int main(int argc, char **argv) { @autoreleasepool {
    device = MTLCreateSystemDefaultDevice();
    if (!device) return 1;
    std::vector<Scenario> scenarios = {
        {"baseline", "one bridge, four frames committed in encode order", [] {
            id<MTLCommandQueue> q = [device newCommandQueue];
            BG3MFXMetal4Bridge *x = makeBridge("X");
            std::vector<Frame *> f;
            for (int i = 0; i < 4; ++i) f.push_back(encodeFrame(q, ("F" + std::to_string(i + 1)).c_str(), {{x, "X"}}));
            for (Frame *frame : f) commit(frame);
            report("baseline: in order, one bridge", f);
        }},
        {"recreate", "F1 via old bridge X, X dropped, F2-F3 via new bridge Y; in order", [] {
            id<MTLCommandQueue> q = [device newCommandQueue];
            Frame *f1, *f2, *f3;
            { BG3MFXMetal4Bridge *x = makeBridge("X"); f1 = encodeFrame(q, "F1(X)", {{x, "X"}}); }
            BG3MFXMetal4Bridge *y = makeBridge("Y");
            f2 = encodeFrame(q, "F2(Y)", {{y, "Y"}}); f3 = encodeFrame(q, "F3(Y)", {{y, "Y"}});
            commit(f1); commit(f2); commit(f3);
            report("recreate: old bridge released before its frame commits", {f1, f2, f3});
        }},
        {"recreate-late", "F1 via old X committed 1 s late; F2 via new Y on the same queue", [] {
            id<MTLCommandQueue> q = [device newCommandQueue];
            Frame *f1, *f2;
            { BG3MFXMetal4Bridge *x = makeBridge("X"); f1 = encodeFrame(q, "F1(X)", {{x, "X"}}); }
            BG3MFXMetal4Bridge *y = makeBridge("Y");
            f2 = encodeFrame(q, "F2(Y)", {{y, "Y"}});
            enqueue(f1); enqueue(f2);
            commitAfter(f1, 1.0); commit(f2);
            report("recreate-late: old bridge's frame committed 1 s late (queue order kept by enqueue)", {f1, f2});
        }},
        {"swap-same", "one bridge; F2 committed before F1 on the same queue", [] {
            id<MTLCommandQueue> q = [device newCommandQueue];
            BG3MFXMetal4Bridge *x = makeBridge("X");
            Frame *f1 = encodeFrame(q, "F1(X)", {{x, "X"}}), *f2 = encodeFrame(q, "F2(X)", {{x, "X"}});
            commit(f2); commit(f1);
            report("swap-same: same bridge, commit order reversed on one queue", {f1, f2});
        }},
        {"swap-recreate", "F1 via old X, F2 via new Y; F2 committed first on the same queue", [] {
            id<MTLCommandQueue> q = [device newCommandQueue];
            Frame *f1, *f2;
            { BG3MFXMetal4Bridge *x = makeBridge("X"); f1 = encodeFrame(q, "F1(X)", {{x, "X"}}); }
            BG3MFXMetal4Bridge *y = makeBridge("Y");
            f2 = encodeFrame(q, "F2(Y)", {{y, "Y"}});
            commit(f2); commit(f1);
            report("swap-recreate: different bridges, commit order reversed on one queue", {f1, f2});
        }},
        {"abandon-old", "F1 via old X never committed; F2-F3 via new Y", [] {
            id<MTLCommandQueue> q = [device newCommandQueue];
            Frame *f1, *f2, *f3;
            { BG3MFXMetal4Bridge *x = makeBridge("X"); f1 = encodeFrame(q, "F1(X)", {{x, "X"}}); }
            BG3MFXMetal4Bridge *y = makeBridge("Y");
            f2 = encodeFrame(q, "F2(Y)", {{y, "Y"}}); f3 = encodeFrame(q, "F3(Y)", {{y, "Y"}});
            commit(f2); commit(f3);
            f1->buffer = nil;
            report("abandon-old: old bridge's frame discarded, new bridge continues", {f2, f3}, {f1});
        }},
        {"abandon-same", "one bridge; F1 never committed, F2-F3 committed", [] {
            id<MTLCommandQueue> q = [device newCommandQueue];
            BG3MFXMetal4Bridge *x = makeBridge("X");
            Frame *f1 = encodeFrame(q, "F1(X)", {{x, "X"}});
            Frame *f2 = encodeFrame(q, "F2(X)", {{x, "X"}}), *f3 = encodeFrame(q, "F3(X)", {{x, "X"}});
            commit(f2); commit(f3);
            f1->buffer = nil;
            report("abandon-same: a discarded frame ahead of later frames on the same bridge", {f2, f3}, {f1});
        }},
        {"late-cross-queue", "one bridge; F1 on queue A committed 1 s late, F2 on queue B on time", [] {
            id<MTLCommandQueue> a = [device newCommandQueue], b = [device newCommandQueue];
            BG3MFXMetal4Bridge *x = makeBridge("X");
            Frame *f1 = encodeFrame(a, "F1(X)A", {{x, "X"}}), *f2 = encodeFrame(b, "F2(X)B", {{x, "X"}});
            commitAfter(f1, 1.0); commit(f2);
            report("late-cross-queue: a late buffer on one queue holds back another queue's frame", {f1, f2});
        }},
        {"late-3.5", "one bridge; F1 committed 3.5 s after encode, F2 on another queue on time", [] {
            id<MTLCommandQueue> a = [device newCommandQueue], b = [device newCommandQueue];
            BG3MFXMetal4Bridge *x = makeBridge("X");
            Frame *f1 = encodeFrame(a, "F1(X)A", {{x, "X"}}), *f2 = encodeFrame(b, "F2(X)B", {{x, "X"}});
            commitAfter(f1, 3.5); commit(f2);
            report("late-3.5: just under the observed 4 s limit", {f1, f2});
        }},
        {"late-4.5", "one bridge; F1 committed 4.5 s after encode, F2 on another queue on time", [] {
            id<MTLCommandQueue> a = [device newCommandQueue], b = [device newCommandQueue];
            BG3MFXMetal4Bridge *x = makeBridge("X");
            Frame *f1 = encodeFrame(a, "F1(X)A", {{x, "X"}}), *f2 = encodeFrame(b, "F2(X)B", {{x, "X"}});
            commitAfter(f1, 4.5); commit(f2);
            report("late-4.5: just over the observed 4 s limit", {f1, f2});
        }},
        {"two-bridges", "Temporal-like T and FG-like G in each frame; G recreated after F1; F2 committed first", [] {
            id<MTLCommandQueue> q = [device newCommandQueue];
            BG3MFXMetal4Bridge *t = makeBridge("T");
            Frame *f1, *f2;
            { BG3MFXMetal4Bridge *g = makeBridge("G-old"); f1 = encodeFrame(q, "F1(T,Gold)", {{t, "T"}, {g, "G-old"}}); }
            BG3MFXMetal4Bridge *g2 = makeBridge("G-new");
            f2 = encodeFrame(q, "F2(T,Gnew)", {{t, "T"}, {g2, "G-new"}});
            commit(f2); commit(f1);
            report("two-bridges: shared Temporal bridge, recreated FG bridge, reversed commits", {f1, f2});
        }},
    };
    if (argc < 2) {
        printf("Scenarios (pass names, or 'all'):\n");
        for (auto &s : scenarios) printf("  %-17s %s\n", s.name, s.description);
        return 0;
    }
    start = CACurrentMediaTime();
    for (int i = 1; i < argc; ++i)
        for (auto &s : scenarios)
            if (!strcmp(argv[i], "all") || !strcmp(argv[i], s.name)) { start = CACurrentMediaTime(); s.run(); }
    return 0;
}}
