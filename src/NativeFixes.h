#pragma once
#import <Foundation/Foundation.h>
#include <cstdint>

// Fixes for BG3 4.1.1.7631656 behavior outside rendering. Each intercepts an
// imported function at verified game call sites only; every other caller gets
// the original function. Installed by BG3MFXInstallNativeMenu after its build
// guard.
//
// Idle waits: BG3's frame limiter (ls::GameClock::CapFrame, which also paces
// the server thread) and its job scheduler's idle loop
// (ls::WorkerThreadScheduler::DoWork) wait by calling pthread_yield_np in a
// loop. At a 30 FPS cap that keeps about three cores busy doing nothing. At
// those sites a short spin is followed by short sleeps. BG3MFX_IDLE_WAIT=0
// restores the original spinning.
//
// Window rebind click: after cocoa::CocoaWindow::BindSurface swaps the window's
// content view (as when the render resolution changes) BG3 posts a left mouse
// click at the cursor, through the system event tap, to focus the new view.
// The click switches BG3's UI from controller to mouse and keyboard and can
// press whatever is under the hidden cursor. While BG3 is the active app,
// bg3mfx makes the new view first responder directly instead.
// BG3MFX_KEEP_REBIND_CLICK=1 keeps BG3's click.
BOOL BG3MFXInstallNativeFixes(intptr_t slide, void (*report)(NSDictionary *));
// Lab A/B switch for the idle-wait fix.
void BG3MFXSetIdleWaitFix(bool enabled);
