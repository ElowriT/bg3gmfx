# MetalFX Sharpening

Technical name: `metalfx-sharpening`.

Enabled by default with MetalFX Spatial and Temporal;
`BG3MFX_METALFX_SHARPENING=0` keeps MetalFX's unsharpened output. The strength
is BG3's own Sharpness setting.

MetalFX replaces both BG3's FSR (EASU) and its RCAS sharpening pass, so the
Sharpness slider used to do nothing for MetalFX and its output looked soft next
to FSR 1.0. BG3's native chain is `FSR_Tonemap` (c / (1 + max c)), FSR and
`FSR_RCAS`, which sharpens in that space, leaves hair (its hair mask) alone and
writes linear HDR (c / (1 − max c)).

[`Sharpening.mm`](../../../src/features/metalfx-sharpening/Sharpening.mm) lets
MetalFX write a pooled texture, maps it into FSR's space in a half-float texture
(rounded up, because the undo magnifies rounding near white and BG3's RG11B10
targets round toward zero), and replays BG3's own `FSR_RCAS` dispatch with its
pipeline, constants, hair mask and grid into the final target. The RCAS
dispatch is captured in [`Trace.mm`](../../../src/integration/renderer/Trace.mm),
which tracks compute constant bindings in MetalFX mode for it. No game shader is
copied.

Live on October 19, 2026 (BG3 4.1.1.7631656, M5 Pro, 1920×1080 output,
Temporal Ultra Quality, default sharpness 0.8): matched frames measured about
60% more edge detail, with mean brightness within 0.5%; the player found the
default strength a little strong for Temporal and can lower the slider. The
cost is one full-screen kernel plus BG3's own RCAS. The Spatial, Temporal and
Frame Generation hook tests check that RCAS runs once per upscaled frame on the
MetalFX result and that the round trip leaves unsharpened colors unchanged.
