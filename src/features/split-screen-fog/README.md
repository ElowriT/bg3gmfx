# Split-Screen Fog Fix

Technical name: `split-screen-fog`.

Enabled by default; `BG3MFX_SPLIT_SCREEN_FOG=0` restores BG3's original
pipeline. It changes nothing in a single view.

BG3 draws its volumetric fog composite (`DeferredFog_*_PS`) once per view with
a fullscreen triangle whose texCoord spans that view only, paired with
`DefaultVS`, which passes texCoord through. The fragment shader reads the fog
volume, which holds every split-screen view side by side, with render-target
UVs, as every other full-screen pass gets from `PPDefaultVS`
(texCoord × `g_ViewportScale` + `g_ViewportOffset`). In split screen each view
therefore sampled fog belonging to another part of the screen: hard-edged,
misplaced smoke and light shafts.

When BG3 creates that pipeline,
[`SplitScreenFog.mm`](../../../src/features/split-screen-fog/SplitScreenFog.mm)
gives it a bg3mfx vertex function with the same interface that applies the
view's scale and offset (BG3 binds its Viewport constants to vertex buffer 9 for
every full-screen pass). The hook is in
[`Trace.mm`](../../../src/integration/renderer/Trace.mm) at render-pipeline
creation; no game shader is copied or modified.

Live on October 18–19, 2026 (BG3 4.1.1.7631656, M5 Pro, two-player split
screen): lab dumps showed the fog pass sampling with view-relative UVs, and a
same-camera A/B removed the misplaced light shafts; the player confirmed the
fix and that a single view is unchanged. `split-screen-fog-smoke` checks that a
`DefaultVS` + `DeferredFog_*_PS` pipeline drawn into the right half receives
render-target UVs, other passes are unchanged, and the switch turns it off.
