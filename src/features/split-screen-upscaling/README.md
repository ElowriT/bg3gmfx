# Split-Screen Upscaling

Technical name: `split-screen-upscaling`.

Active with MetalFX Spatial and Temporal whenever BG3 renders more than one
view. A single view is unchanged.

In split screen BG3 renders each view into its own rectangle of shared
full-size textures and runs FSR over the whole frame once per view. The
Temporal scene capture skipped those viewports, so Temporal fell back to BG3's
FSR 1.0 every split-screen frame, and an upscaler fed the whole texture blends
the two views at the seam (visible on faces near the middle of the screen).

[`Trace.mm`](../../../src/integration/renderer/Trace.mm) now reads each TAA
draw's view from BG3's Viewport constants and carries it to that view's FSR
dispatch. [`ViewRegions.mm`](../../../src/features/split-screen-upscaling/ViewRegions.mm)
crops the view's color, depth and motion into pooled view-sized textures, the
view is upscaled by a scaler of its own (keyed by size and position, so each
view keeps its own Temporal history), and the result is placed into the view's
rectangle of the output. Both edges of neighbouring rectangles round the same
way, so the views meet exactly. BG3's RCAS replay runs once per view over the
whole frame, as BG3 does, and reads a half-float copy.

In split screen BG3 also blit-copies scene color between post-processing passes
(bloom's result into colour grading's input), which used to break the pass chain
from TAA to FSR. Blit copies of a tracked scene texture now carry its frame
along, like the recognized color passes. With `BG3MFX_LAB` set, the capture per
view, the pass chain, copies, FSR lookups and native fallbacks are logged to
`input-log.jsonl`.

Live on October 19, 2026 (BG3 4.1.1.7631656, M5 Pro, two-player split screen,
1706×960 → 2560×1440, Temporal Quality): the seam artifact on faces was gone and
Temporal no longer fell back to FSR; MetalFX Temporal cost about 2 ms per view
on its Metal 4 queue (`metal4MsPerFrame` in lab `perf.json`). Rechecked on the
0.3.0 layout the same day with two lab virtual controllers (1200×779 →
1800×1169, Temporal): both views captured, chained and upscaled, no native
fallback after the 0.3 s settle at the split, none while both cameras turned,
about 2.1 ms of MetalFX time for both views, and no visible seam. In split
screen the Metal HUD shows "Jitter Sequence Len 1": both views' scalers encode
the same jitter one after the other. BG3's TAA constants still change the jitter
every frame, as in a single view.
`split-screen-upscale-smoke` renders two views with different contents and
checks that each output half holds only its own view, that every view gets its
own Temporal scaler, and that a single view still uses one.
