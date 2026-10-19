#pragma once
#import <Foundation/Foundation.h>

// Lab mode only: one timeline (input-log.jsonl in the lab directory) of AppKit
// input events, game controller changes, cursor warps and synthetic mouse
// events the game posts (with unslid return addresses for atos), plus bg3mfx
// events noted by the runtime. For diagnosing BG3 switching its UI between
// controller and mouse/keyboard.
void BG3MFXLabInputStart(NSString *directory);
void BG3MFXLabInputNote(NSDictionary *event);
