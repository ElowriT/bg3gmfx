#pragma once
#import <Foundation/Foundation.h>

// Lab mode only: one timeline (input-log.jsonl in the lab directory) of AppKit
// input events, game controller changes, cursor warps and synthetic mouse
// events the game posts (with unslid return addresses for atos), plus bg3mfx
// events noted by the runtime. For diagnosing BG3 switching its UI between
// controller and mouse/keyboard.
void BG3MFXLabInputStart(NSString *directory);
void BG3MFXLabInputNote(NSDictionary *event);

// Lab mode only: up to four virtual game controllers, driven by control.txt
// "pad N ..." lines (see docs/dev/lab.md). Takes every pad line of the file
// without its "pad " prefix; a pad with no line is disconnected. Returns the
// pads' last known state (player index BG3 assigned, whether it installed a
// change handler, held buttons) for status.json.
NSArray<NSDictionary *> *BG3MFXLabPadsApply(NSArray<NSString *> *lines);
