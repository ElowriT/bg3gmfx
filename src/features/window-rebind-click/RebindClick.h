#pragma once
#import <Foundation/Foundation.h>
#include <cstdint>

// After cocoa::CocoaWindow::BindSurface swaps the window's content view (as when
// the render resolution or display mode changes), BG3 posts a left mouse click
// at the cursor through the HID event tap to focus the new view. The click
// switches BG3's UI from controller to mouse and keyboard and can press
// whatever lies under the hidden cursor. While BG3 is the active app, bg3mfx
// drops that click; the view keeps or regains first responder (custom-menu's
// render view focus repair, or here if it did not). The window-rebind-click
// feature (BG3MFX_FEATURE_WINDOW_REBIND_CLICK=1) installs it on the supported
// build; it stays off if the call sites differ.
BOOL BG3MFXInstallRebindClickFix(intptr_t slide, void (*report)(NSDictionary *), NSError **error);
