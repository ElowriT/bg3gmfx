#pragma once
#import <Foundation/Foundation.h>
#include <cstdint>

// After cocoa::CocoaWindow::BindSurface swaps the window's content view (as when
// the render resolution or display mode changes), BG3 posts a left mouse click
// at the cursor through the HID event tap to focus the new view. The click
// switches BG3's UI from controller to mouse and keyboard and can press
// whatever lies under the hidden cursor. While BG3 is the active app, bg3mfx
// drops that click; the view keeps or regains first responder (the Video
// Options focus repair in NativeMenu.mm, or here if it did not).
// BG3MFX_KEEP_REBIND_CLICK=1 keeps BG3's click. Installed by
// BG3MFXInstallNativeMenu after its build guard; stays off if the call sites
// differ.
BOOL BG3MFXInstallRebindClickFix(intptr_t slide, void (*report)(NSDictionary *));
