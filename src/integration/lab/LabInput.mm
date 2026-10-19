#import "integration/lab/LabInput.h"
#import <AppKit/AppKit.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#include <atomic>
#include <dlfcn.h>
#include <execinfo.h>
#include <mach-o/dyld.h>
#include <unistd.h>

static std::atomic<bool> logging{false};
static NSFileHandle *output;
static dispatch_queue_t writer;
static std::atomic<unsigned> lines{0};
static const unsigned lineLimit = 400000;

static void writeLine(NSDictionary *event) {
    if (!logging.load(std::memory_order_relaxed) || lines.fetch_add(1) >= lineLimit) return;
    NSMutableDictionary *stamped = [event mutableCopy];
    stamped[@"t"] = @(CACurrentMediaTime());
    dispatch_async(writer, ^{
        NSData *data = [NSJSONSerialization dataWithJSONObject:stamped options:NSJSONWritingSortedKeys error:nil];
        if (!data) return;
        [output writeData:data];
        [output writeData:[NSData dataWithBytes:"\n" length:1]];
    });
}

void BG3MFXLabInputNote(NSDictionary *event) { writeLine(@{@"bg3mfx": event}); }

// Return addresses inside the game executable, unslid for `atos -l 0x100000000`.
static NSArray *gameCallers() {
    void *frames[24];
    int count = backtrace(frames, 24);
    static uint32_t game = [] { for (uint32_t i = 0; i < _dyld_image_count(); ++i) if (_dyld_get_image_header(i)->filetype == MH_EXECUTE) return i; return 0u; }();
    intptr_t slide = _dyld_get_image_vmaddr_slide(game);
    NSMutableArray *callers = [NSMutableArray array];
    for (int i = 1; i < count; ++i) {
        Dl_info info{};
        if (dladdr(frames[i], &info) && info.dli_fbase == _dyld_get_image_header(game))
            [callers addObject:[NSString stringWithFormat:@"0x%lx", (unsigned long)((intptr_t)frames[i] - slide)]];
    }
    return callers;
}

// The game imports these to move the system cursor (CGEventPost is logged by the window-rebind-click fix).
static CGError labWarp(CGPoint point) {
    if (logging) writeLine(@{@"call": @"CGWarpMouseCursorPosition", @"x": @(point.x), @"y": @(point.y), @"callers": gameCallers()});
    return CGWarpMouseCursorPosition(point);
}
static CGError labMoveCursor(CGDirectDisplayID display, CGPoint point) {
    if (logging) writeLine(@{@"call": @"CGDisplayMoveCursorToPoint", @"display": @(display), @"x": @(point.x), @"y": @(point.y), @"callers": gameCallers()});
    return CGDisplayMoveCursorToPoint(display, point);
}
#define BG3MFX_INTERPOSE(replacement, replacee) \
    __attribute__((used)) static struct { const void *r; const void *o; } interpose_##replacee \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)&replacement, (const void *)&replacee };
BG3MFX_INTERPOSE(labWarp, CGWarpMouseCursorPosition)
BG3MFX_INTERPOSE(labMoveCursor, CGDisplayMoveCursorToPoint)

static NSDictionary *describe(NSEvent *event) {
    NSMutableDictionary *d = [@{@"event": @(event.type), @"eventTime": @(event.timestamp)} mutableCopy];
    if (CGEventRef cg = event.CGEvent) {
        // A posted event names its source process; hardware input has none.
        int64_t pid = CGEventGetIntegerValueField(cg, kCGEventSourceUnixProcessID);
        if (pid) d[@"sourcePid"] = @(pid);
        d[@"sourceState"] = @(CGEventGetIntegerValueField(cg, kCGEventSourceStateID));
    }
    switch (event.type) {
        case NSEventTypeKeyDown: case NSEventTypeKeyUp:
            d[@"key"] = @(event.keyCode); d[@"repeat"] = @(event.isARepeat); break;
        case NSEventTypeFlagsChanged: d[@"flags"] = @(event.modifierFlags); break;
        case NSEventTypeMouseMoved: case NSEventTypeLeftMouseDragged: case NSEventTypeRightMouseDragged:
        case NSEventTypeLeftMouseDown: case NSEventTypeLeftMouseUp: case NSEventTypeRightMouseDown: case NSEventTypeRightMouseUp:
        case NSEventTypeScrollWheel: case NSEventTypeMouseEntered: case NSEventTypeMouseExited:
            d[@"x"] = @(event.locationInWindow.x); d[@"y"] = @(event.locationInWindow.y);
            d[@"dx"] = @(event.deltaX); d[@"dy"] = @(event.deltaY); break;
        default: break;
    }
    return d;
}

// Main thread: the screen, window and Metal layer sizes that decide how BG3's
// output reaches the display.
static void findLayers(CALayer *layer, NSMutableArray *out) {
    if ([layer isKindOfClass:CAMetalLayer.class]) {
        CAMetalLayer *m = (CAMetalLayer *)layer;
        [out addObject:@{@"drawable": @[@(m.drawableSize.width), @(m.drawableSize.height)], @"bounds": @[@(m.bounds.size.width), @(m.bounds.size.height)],
                         @"contentsScale": @(m.contentsScale), @"format": @(m.pixelFormat), @"displaySync": @(m.displaySyncEnabled),
                         @"maximumDrawableCount": @(m.maximumDrawableCount), @"framebufferOnly": @(m.framebufferOnly)}];
    }
    for (CALayer *child in layer.sublayers) findLayers(child, out);
}
static void logDisplay(NSString *reason) {
    NSMutableArray *windows = [NSMutableArray array];
    for (NSWindow *w in NSApp.windows) {
        if (!w.isVisible) continue;
        NSMutableArray *layers = [NSMutableArray array];
        findLayers(w.contentView.layer, layers);
        NSScreen *s = w.screen;
        [windows addObject:@{@"frame": NSStringFromRect(w.frame), @"fullScreen": @((w.styleMask & NSWindowStyleMaskFullScreen) != 0),
            @"screen": NSStringFromRect(s.frame), @"backingScale": @(s.backingScaleFactor), @"screenName": s.localizedName ?: @"",
            @"maxFPS": @(s.maximumFramesPerSecond), @"layers": layers}];
    }
    writeLine(@{@"display": reason, @"windows": windows});
}

void BG3MFXLabInputStart(NSString *directory) {
    NSString *path = [directory stringByAppendingPathComponent:@"input-log.jsonl"];
    [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
    output = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!output) return;
    writer = dispatch_queue_create("bg3mfx.lab.input", DISPATCH_QUEUE_SERIAL);
    logging = true;
    writeLine(@{@"start": @(getpid())});
    for (NSString *name in @[GCControllerDidConnectNotification, GCControllerDidDisconnectNotification,
                             GCControllerDidBecomeCurrentNotification, GCControllerDidStopBeingCurrentNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            GCController *controller = note.object;
            writeLine(@{@"controller": name, @"name": controller.vendorName ?: @"", @"player": @(controller.playerIndex)});
        }];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskAny handler:^NSEvent *(NSEvent *event) {
            writeLine(describe(event));
            return event;
        }];
        for (NSString *name in @[NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification, NSWindowDidResizeNotification,
                                 NSWindowDidChangeScreenNotification, NSApplicationDidBecomeActiveNotification, NSApplicationDidResignActiveNotification]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *) {
                writeLine(@{@"notification": name});
                logDisplay(name);
            }];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ logDisplay(@"startup"); });
    });
}
