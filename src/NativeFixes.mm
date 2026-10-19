#import "NativeFixes.h"
#import "LabInput.h"
#import <AppKit/AppKit.h>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <mach/mach_time.h>
#include <pthread.h>
#include <time.h>

static intptr_t gameSlide;
static std::atomic<bool> installed{false}, idleWaitFix{false}, rebindClickFix{false};

// Return addresses (unslid) of the game's calls, and the import stubs they call.
static const uintptr_t yieldStub = 0x1077cd490, eventPostStub = 0x1077caee0;
struct IdleSite { uintptr_t returnAddress; uint32_t spinYields; uint32_t sleepMicroseconds; };
static const IdleSite idleSites[] = {
    {0x1064d1e98, 16, 250},  // GameClock::CapFrame, waiting while helping with jobs
    {0x1064d1f6c, 16, 250},  // GameClock::CapFrame, final wait
    {0x106551c98, 64, 100},  // WorkerThreadScheduler::DoWork, no job to schedule
};
static const uintptr_t rebindClickSites[] = {0x100bb4218, 0x100bb4248};  // CocoaWindow::BindSurface: down, up

static bool callsStub(uintptr_t returnAddress, uintptr_t stub) {
    uint32_t instruction;
    memcpy(&instruction, reinterpret_cast<const void *>(returnAddress - 4 + gameSlide), 4);
    if ((instruction & 0xfc000000) != 0x94000000) return false;  // BL
    int64_t offset = (int64_t)(int32_t)(instruction << 6) >> 6;
    return returnAddress - 4 + offset * 4 == stub;
}

// A brief spin keeps short waits responsive; a thread that keeps waiting
// sleeps instead. A gap since its previous call means it did other work.
static void idleWait(const IdleSite &site) {
    static mach_timebase_info_data_t timebase = [] { mach_timebase_info_data_t t; mach_timebase_info(&t); return t; }();
    static thread_local uint64_t last;
    static thread_local uint32_t streak;
    uint64_t now = mach_absolute_time();
    if ((now - last) * timebase.numer / timebase.denom > 1000000) streak = 0;
    if (streak < site.spinYields) {
        ++streak;
        last = now;
        pthread_yield_np();
        return;
    }
    timespec pause = {0, (long)site.sleepMicroseconds * 1000};
    nanosleep(&pause, nullptr);
    last = mach_absolute_time();
}

static void bg3mfxYield(void) {
    if (idleWaitFix.load(std::memory_order_relaxed)) {
        uintptr_t site = (uintptr_t)__builtin_return_address(0) - gameSlide;
        for (const IdleSite &idle : idleSites) if (site == idle.returnAddress) { idleWait(idle); return; }
    }
    pthread_yield_np();
}

static void bg3mfxPost(CGEventTapLocation tap, CGEventRef event) {
    uintptr_t site = (uintptr_t)__builtin_return_address(0) - gameSlide;
    bool rebind = installed.load(std::memory_order_relaxed) && (site == rebindClickSites[0] || site == rebindClickSites[1]);
    bool replace = rebind && rebindClickFix.load(std::memory_order_relaxed) && NSRunningApplication.currentApplication.isActive;
    CGPoint location = CGEventGetLocation(event);
    BG3MFXLabInputNote(@{@"call":@"CGEventPost", @"type":@(CGEventGetType(event)), @"x":@(location.x), @"y":@(location.y),
                         @"site":[NSString stringWithFormat:@"0x%lx", (unsigned long)site], @"rebindClick":@(rebind), @"replaced":@(replace)});
    if (!replace) { CGEventPost(tap, event); return; }
    // Do what the click is for: focus the new content view.
    if (CGEventGetType(event) == kCGEventLeftMouseDown) {
        void (^focus)(void) = ^{
            NSWindow *window = NSApp.keyWindow ?: NSApp.mainWindow;
            if (window.contentView) [window makeFirstResponder:window.contentView];
        };
        if (NSThread.isMainThread) focus(); else dispatch_async(dispatch_get_main_queue(), focus);
    }
}

#define BG3MFX_INTERPOSE(replacement, replacee) \
    __attribute__((used)) static struct { const void *r; const void *o; } interpose_##replacee \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)&replacement, (const void *)&replacee };
BG3MFX_INTERPOSE(bg3mfxYield, pthread_yield_np)
BG3MFX_INTERPOSE(bg3mfxPost, CGEventPost)

static bool envOff(const char *name) { const char *v = getenv(name); return v && !strcmp(v, "0"); }
static bool envOn(const char *name) { const char *v = getenv(name); return v && !strcmp(v, "1"); }

BOOL BG3MFXInstallNativeFixes(intptr_t slide, void (*report)(NSDictionary *)) {
    gameSlide = slide;
    bool sitesMatch = true;
    for (const IdleSite &idle : idleSites) sitesMatch = sitesMatch && callsStub(idle.returnAddress, yieldStub);
    for (uintptr_t click : rebindClickSites) sitesMatch = sitesMatch && callsStub(click, eventPostStub);
    if (!sitesMatch) {
        if (report) report(@{@"event":@"nativeFixesUnavailable", @"reason":@"Game call sites do not match the supported build."});
        return NO;
    }
    idleWaitFix = !envOff("BG3MFX_IDLE_WAIT");
    rebindClickFix = !envOn("BG3MFX_KEEP_REBIND_CLICK");
    installed = true;
    if (report) report(@{@"event":@"nativeFixesInstalled", @"idleWait":@(idleWaitFix.load()), @"rebindClick":@(rebindClickFix.load())});
    return YES;
}

void BG3MFXSetIdleWaitFix(bool enabled) { if (installed) idleWaitFix = enabled; }
