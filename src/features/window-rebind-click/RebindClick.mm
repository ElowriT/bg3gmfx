#include "common/Feature.h"
#import "features/window-rebind-click/RebindClick.h"
#import "features/metalfx/lab/LabInput.h"
#import "common/native/SupportedBuild.h"
#import <AppKit/AppKit.h>
#include <atomic>
#include <cstdlib>
#include <cstring>

static intptr_t gameSlide;
static std::atomic<bool> installed{false};

// Unslid, from the supported-build manifest.
static const uintptr_t rebindClickSites[] = {BG3MFXBuild::RebindClick::MouseDownReturn, BG3MFXBuild::RebindClick::MouseUpReturn};
static const uintptr_t eventPostStub = BG3MFXBuild::RebindClick::EventPostStub;

static bool callsStub(uintptr_t returnAddress, uintptr_t stub) {
    uint32_t instruction;
    memcpy(&instruction, reinterpret_cast<const void *>(returnAddress - 4 + gameSlide), 4);
    if ((instruction & 0xfc000000) != 0x94000000) return false;  // BL
    int64_t offset = (int64_t)(int32_t)(instruction << 6) >> 6;
    return returnAddress - 4 + offset * 4 == stub;
}

static void bg3mfxPost(CGEventTapLocation tap, CGEventRef event) {
    uintptr_t site = (uintptr_t)__builtin_return_address(0) - gameSlide;
    bool rebind = installed.load(std::memory_order_relaxed) && (site == rebindClickSites[0] || site == rebindClickSites[1]);
    bool replace = rebind && NSRunningApplication.currentApplication.isActive;
    CGPoint location = CGEventGetLocation(event);
    BG3MFXLabInputNote(@{@"call":@"CGEventPost", @"type":@(CGEventGetType(event)), @"x":@(location.x), @"y":@(location.y),
                         @"site":[NSString stringWithFormat:@"0x%lx", (unsigned long)site], @"rebindClick":@(rebind), @"replaced":@(replace)});
    if (!replace) { CGEventPost(tap, event); return; }
    // Do what the click is for, unless the focus repair already did: focus the new content view.
    if (CGEventGetType(event) == kCGEventLeftMouseDown) {
        void (^focus)(void) = ^{
            NSWindow *window = NSApp.keyWindow ?: NSApp.mainWindow;
            if (window.contentView && window.firstResponder != window.contentView) [window makeFirstResponder:window.contentView];
        };
        if (NSThread.isMainThread) focus(); else dispatch_async(dispatch_get_main_queue(), focus);
    }
}

__attribute__((used)) static struct { const void *replacement; const void *replacee; } interposeEventPost
    __attribute__((section("__DATA,__interpose"))) = { (const void *)&bg3mfxPost, (const void *)&CGEventPost };

BOOL BG3MFXInstallRebindClickFix(intptr_t slide, NSError **error) {
    gameSlide = slide;
    for (uintptr_t click : rebindClickSites) if (!callsStub(click, eventPostStub)) {
        if (error) *error = [NSError errorWithDomain:@"BG3MFX" code:1
            userInfo:@{NSLocalizedDescriptionKey:@"The rebind click call sites do not match the supported build."}];
        return NO;
    }
    installed = true;
    return YES;
}

namespace {
BOOL installRebindClick(const BG3MFXFeatureContext &context, NSError **error) {
    return BG3MFXInstallRebindClickFix(context.slide, error);
}
}
BG3MFX_FEATURE(windowRebindClick, {"window-rebind-click", nullptr, true, installRebindClick, nullptr});
