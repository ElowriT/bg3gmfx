#import "integration/lab/LabInput.h"
#import <AppKit/AppKit.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#include <atomic>
#include <cmath>
#include <memory>
#include <vector>
#include <dlfcn.h>
#include <execinfo.h>
#include <mach-o/dyld.h>
#include <mutex>
#include <objc/runtime.h>
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

// Virtual controllers. BG3 reads controllers through GameController
// ([GCController controllers], the connect notifications, extendedGamepad
// elements and their change handlers), so a simulated controller made with
// +controllerWithExtendedGamepad can join like a real one, for example as the
// second split-screen player. Pads are created and changed on the main thread.
static const int padLimit = 4;
static GCController *pads[padLimit];
static std::mutex padLock;
static NSArray<NSDictionary *> *padState = @[];
static IMP originalControllers;

static NSArray *labControllers(id self, SEL cmd) {
    NSArray *list = ((NSArray *(*)(id,SEL))originalControllers)(self, cmd);
    std::lock_guard<std::mutex> lock(padLock);
    NSMutableArray *all = nil;
    for (GCController *pad : pads) if (pad) { if (!all) all = [list mutableCopy] ?: [NSMutableArray array]; [all addObject:pad]; }
    return all ?: list;
}

// The first calls BG3 makes on a virtual pad, for the timeline.
static void notePadQuery(NSString *selector) {
    static std::atomic<unsigned> queries{0};
    if (queries.fetch_add(1) < 40) BG3MFXLabInputNote(@{@"event": @"padQuery", @"selector": selector});
}

// Presented as an Xbox controller: BG3 picks button glyphs by product.
static Class padClass(GCController *controller) {
    static Class cls;
    if (!cls) {
        cls = objc_allocateClassPair(object_getClass(controller), "BG3MFXLabController", 0);
        class_addMethod(cls, @selector(vendorName), imp_implementationWithBlock(^NSString *(id) {
            notePadQuery(@"vendorName"); return @"Xbox Wireless Controller"; }), "@@:");
        class_addMethod(cls, @selector(productCategory), imp_implementationWithBlock(^NSString *(id) {
            notePadQuery(@"productCategory"); return @"Xbox One"; }), "@@:");
        objc_registerClassPair(cls);
    }
    return cls;
}

static NSDictionary<NSString *, NSString *> *padButtons() {
    static NSDictionary *names = @{@"a": @"buttonA", @"b": @"buttonB", @"x": @"buttonX", @"y": @"buttonY",
        @"lb": @"leftShoulder", @"rb": @"rightShoulder", @"lt": @"leftTrigger", @"rt": @"rightTrigger",
        @"l3": @"leftThumbstickButton", @"r3": @"rightThumbstickButton", @"menu": @"buttonMenu",
        @"options": @"buttonOptions", @"home": @"buttonHome"};
    return names;
}

// -setValue: on a simulated controller changes the element but calls no change
// handler, so they are called here as a real controller's input would: the
// element's handlers, then the profile's.
static void changed(GCExtendedGamepad *gamepad, GCControllerElement *element) {
    if (auto handler = gamepad.valueChangedHandler) handler(gamepad, element);
}
static void setButton(GCExtendedGamepad *gamepad, GCControllerButtonInput *button, float value) {
    if (!button || button.value == value) return;
    bool wasPressed = button.pressed;
    [button setValue:value];
    if (auto handler = button.pressedChangedHandler; handler && button.pressed != wasPressed) handler(button, button.value, button.pressed);
    if (auto handler = button.valueChangedHandler) handler(button, button.value, button.pressed);
    changed(gamepad, button);
}
static void setAxes(GCExtendedGamepad *gamepad, GCControllerDirectionPad *pad, float x, float y) {
    if (!pad || (pad.xAxis.value == x && pad.yAxis.value == y)) return;
    [pad setValueForXAxis:x yAxis:y];
    if (auto handler = pad.valueChangedHandler) handler(pad, pad.xAxis.value, pad.yAxis.value);
    changed(gamepad, pad);
}

NSArray<NSDictionary *> *BG3MFXLabPadsApply(NSArray<NSString *> *lines) {
    struct Wanted { bool connected = false; NSMutableSet *held = [NSMutableSet set]; float left[2] = {0, 0}, right[2] = {0, 0}; };
    auto wanted = std::make_shared<std::vector<Wanted>>(padLimit);
    for (NSString *line in lines) {
        NSMutableArray<NSString *> *words = [[line.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet] mutableCopy];
        [words removeObject:@""];
        int index = words.count ? words[0].intValue - 1 : -1;
        if (index < 0 || index >= padLimit) continue;
        Wanted &pad = (*wanted)[index];
        pad.connected = true;
        if (words.count == 5 && [words[1] isEqualToString:@"stick"]) {
            float *stick = [words[2] isEqualToString:@"right"] ? pad.right : pad.left;
            stick[0] = fmaxf(-1, fminf(1, words[3].floatValue)); stick[1] = fmaxf(-1, fminf(1, words[4].floatValue));
            continue;
        }
        for (NSUInteger i = 1; i < words.count; ++i) [pad.held addObject:words[i]];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!originalControllers) {
            Method method = class_getClassMethod(GCController.class, @selector(controllers));
            originalControllers = method_setImplementation(method, (IMP)labControllers);
        }
        NSMutableArray *state = [NSMutableArray array];
        for (int i = 0; i < padLimit; ++i) {
            const Wanted &want = (*wanted)[i];
            GCController *pad;
            { std::lock_guard<std::mutex> lock(padLock); pad = pads[i]; }
            if (!want.connected) {
                if (!pad) continue;
                { std::lock_guard<std::mutex> lock(padLock); pads[i] = nil; }
                [NSNotificationCenter.defaultCenter postNotificationName:GCControllerDidDisconnectNotification object:pad];
                BG3MFXLabInputNote(@{@"event": @"padDisconnected", @"pad": @(i + 1)});
                continue;
            }
            if (!pad) {
                pad = [GCController controllerWithExtendedGamepad];
                if (!pad) continue;
                object_setClass(pad, padClass(pad));
                { std::lock_guard<std::mutex> lock(padLock); pads[i] = pad; }
                [NSNotificationCenter.defaultCenter postNotificationName:GCControllerDidConnectNotification object:pad];
                BG3MFXLabInputNote(@{@"event": @"padConnected", @"pad": @(i + 1)});
            }
            GCExtendedGamepad *gamepad = pad.extendedGamepad;
            NSMutableArray *unknown = [NSMutableArray array];
            for (NSString *name in want.held)
                if (!padButtons()[name] && ![@[@"up", @"down", @"left", @"right"] containsObject:name]) [unknown addObject:name];
            bool menuWasPressed = gamepad.buttonMenu.pressed;
            [padButtons() enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *key, BOOL *) {
                setButton(gamepad, [gamepad valueForKey:key], [want.held containsObject:name] ? 1 : 0);
            }];
            // BG3 takes the Menu button from the controller's pause handler.
            if (!menuWasPressed && gamepad.buttonMenu.pressed) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                if (auto paused = pad.controllerPausedHandler) paused(pad);
#pragma clang diagnostic pop
            }
            setAxes(gamepad, gamepad.dpad, ([want.held containsObject:@"right"] ? 1 : 0) - ([want.held containsObject:@"left"] ? 1 : 0),
                    ([want.held containsObject:@"up"] ? 1 : 0) - ([want.held containsObject:@"down"] ? 1 : 0));
            setAxes(gamepad, gamepad.leftThumbstick, want.left[0], want.left[1]);
            setAxes(gamepad, gamepad.rightThumbstick, want.right[0], want.right[1]);
            NSMutableDictionary *entry = [@{@"pad": @(i + 1), @"player": @(pad.playerIndex),
                @"handler": @(gamepad.valueChangedHandler != nil), @"held": [want.held.allObjects sortedArrayUsingSelector:@selector(compare:)],
                @"left": @[@(want.left[0]), @(want.left[1])], @"right": @[@(want.right[0]), @(want.right[1])]} mutableCopy];
            if (unknown.count) entry[@"unknown"] = unknown;
            [state addObject:entry];
        }
        std::lock_guard<std::mutex> lock(padLock);
        padState = state;
    });
    std::lock_guard<std::mutex> lock(padLock);
    return padState;
}
