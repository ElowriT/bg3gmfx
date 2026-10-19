# Window Rebind Click Fix

Technical name: `window-rebind-click`.

Enabled by default; `BG3MFX_KEEP_REBIND_CLICK=1` keeps BG3's click.

After `cocoa::CocoaWindow::BindSurface` swaps the window's content view, as when
a Video option changes the render resolution or display mode, BG3 posts a
synthetic left click (mouse down and up) at the cursor through the HID event
tap so that the new view gets focus. For a player using a controller the click
switches BG3's UI to mouse and keyboard, so the controller stops driving the
menu until the player returns to the game, and the click can press whatever
lies under the hidden cursor. With a MetalFX Upscaling Type saved, simply
opening Video options reapplies it and triggers two such clicks.

[`RebindClick.mm`](../../../src/features/window-rebind-click/RebindClick.mm)
interposes `CGEventPost` and, only for the two verified call sites in
`BindSurface` and only while BG3 is the active app, drops the click. The new
view keeps first responder through the Video Options focus repair in
[`NativeMenu.mm`](../../../src/integration/menu/NativeMenu.mm), or here when
that repair did not apply. Every other caller gets `CGEventPost` unchanged.

Live on October 19, 2026 on BG3 4.1.1.7631656 (before the port onto 0.3.0): the
lab input log showed the two synthetic clicks right after the Video options
rebuilt, and with the fix the player confirmed the controller kept working in
the menu. This port has not yet been rechecked with a controller.
