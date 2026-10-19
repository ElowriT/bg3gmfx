#pragma once
#import <Metal/Metal.h>

// Split-screen volumetric fog. BG3 draws its fog composite (DeferredFog_*_PS)
// once per view with a fullscreen triangle whose texCoord spans that view only,
// paired with DefaultVS, which passes texCoord through. The fragment shader
// reads the fog volume, which holds all views side by side, with render-target
// UVs: the ones every other full-screen pass gets from PPDefaultVS
// (texCoord * g_ViewportScale + g_ViewportOffset). In a single view the two are
// identical; in split screen each view samples fog belonging to the wrong part
// of the screen, which shows as hard-edged, misplaced smoke and light shafts.
//
// Returns a copy of desc whose vertex function applies the viewport mapping, or
// nil when desc is not that pass or BG3MFX_SPLIT_SCREEN_FOG=0 disables the fix.
MTLRenderPipelineDescriptor *BG3MFXSplitScreenFogDescriptor(id<MTLDevice> device, MTLRenderPipelineDescriptor *desc);
