# BG3GMFX validation and measurements

Live checks and measurements of this fork's own changes. BG3MFX 0.4.1 removed
its validation and performance records (`docs/dev/validation/`,
`docs/dev/performance.md`); the fork's entries from them are kept here, newest
work last.

| Feature | Behavior | Validation |
| --- | --- | --- |
| Split screen | Fog composite uses view-relative UV mapping; each view is upscaled on its own | User-confirmed fog and seam fixes in two-player split screen on the 0.2.2-based branch, rechecked on the feature layout with lab virtual controllers; synthetic split-screen tests |
| MetalFX Sharpening | BG3's RCAS replayed on MetalFX output | Live matched-frame detail measurement; hook tests with and without sharpening |
| Window Rebind Click Fix | The synthetic click after a window rebind is replaced by focusing the new view | User confirmed the controller keeps working in Video options on the 0.2.2-based branch |

## Split screen, sharpening and controller input (October 19)

Live on BG3 4.1.1.7631656, M5 Pro, a 2560×1440 display (HiDPI), quiet runtime
in [lab mode](lab.md), with the user playing two-player split screen with
controllers. These sessions ran on the 0.2.2-based branch. On the feature
layout, a single view (Temporal, fog, sharpening on/off: about 30% more edge
detail on matched screenshots) and two-player split screen were rechecked live
the same day, the split screen with two lab virtual controllers: per-view
upscaling without native fallbacks while both cameras turned, and no visible
seam. The window rebind click fix has not been rechecked on this layout.

- Split-screen fog: the user reported "unnatural smoke" in split screen only.
  Lab dumps (copied right after each view's passes) and the fog shaders showed
  that `DeferredFog_*_PS` received view-relative UVs. A live A/B at a fixed
  camera, toggling only the vertex-stage viewport constants, removed the
  hard-edged, misplaced light shafts; the user confirmed the fix in game and that
  a single view is unchanged.
- Controller input: the lab input log showed two synthetic left clicks posted
  by `CocoaWindow::BindSurface` right after the Video options rebuilt with a
  MetalFX mode saved, and after switching to Temporal. With the replacement the
  user confirmed the controller keeps working in the menu.
- Sharpening: matched frames of Temporal Ultra Quality at the default sharpness
  (0.8) measured about 60% more edge detail with BG3's RCAS replayed; mean
  brightness within 0.5%.
- Per-view upscaling: before, split screen ran BG3's FSR every frame ("no
  matching scene color"): the capture skipped split viewports, and BG3's blit
  copies between bloom and colour grading broke the pass chain. With both fixed,
  the lab log shows every view captured, chained and upscaled, with no native
  fallback, and the user confirmed the seam artifacts on faces are gone.
- Costs: MetalFX Temporal's own Metal 4 GPU time was about 2 ms per frame for
  one 1706×960 → 2560×1440 view and about 3 ms for both split-screen views. A
  serialized lab profile put BG3's own GPU work at about 12.8 ms per frame in
  that split-screen scene, with no single dominant pass (geometry about 4 ms,
  volumetric fog 1.6 ms, shadows 1.1 ms).
- CPU: the same sessions found `GameClock::CapFrame` and
  `WorkerThreadScheduler::DoWork` spinning on `pthread_yield_np` (2560×1440
  split screen, 30 FPS: package power 26–28 W, about 17.7 W with sleeps). CPU
  Thread Idling covers these waits, so that fix is not part of this branch.

Synthetic: `split-screen-fog-smoke` (fog pass receives render-target UVs; fails
without the runtime), `split-screen-upscale-smoke` (two views with BG3-style
viewports, blit hop and per-view FSR/RCAS; one scaler per view, no blending at
the seam; fails on the earlier runtime), RCAS replay counts and identity checks
in the Spatial, Temporal and Frame Generation hook tests (with and without
sharpening), and `lab-smoke` for lab mode including the profiler.

## Metal 4 submission order (October 19)

Live on the feature layout (2560×1440, two-player split screen, MetalFX
Temporal): right after the frame cap was turned off, the game ran at about one
frame per second, the kernel logged `AGX: Channel error 2` and denied BG3
further GPU submissions after two GPU restarts, BG3's command buffers failed
with `kIOGPUCommandBufferCallbackErrorTimeout`, and bg3mfx reported
"MetalFX Temporal could not continue" (`MTL4CommandQueueErrorDomain` error 1,
a Metal 4 queue timeout). Bridge submissions reached their Metal 4 queue in
encoding order, while BG3 fixes the GPU order of its buffers with `-enqueue`
after encoding them. `metal4-bridge-smoke` now encodes upscaling into two
buffers in one order and enqueues them in the other: submitted in encoding
order it fails with the same GPU timeout after about 10 s; submitting in
enqueue order alone still stalled about 4 s, because the temporal scaler links
frames in encoding order. With the scaler work recorded at submission time it
completes in milliseconds. `perf.json` reports `metal4Reordered`, the
submissions that this reordered.

Rechecked live on October 20 (started from Steam with the overlay, 2560×1440,
Temporal Quality, frame cap off, two-player split screen with lab virtual
controllers): 60 s at about 86 FPS with the GPU at 100%, no GPU errors in the
kernel log, the game kept running. `metal4Reordered` stayed 0, so the original
trigger (turning the cap off while already in split screen) was not
reproduced. A serialized profile of the same scene: BG3's passes 10.1 ms per
frame plus 2.0 ms of MetalFX (before 0.3.0, 12.8 ms in a similar scene);
post-processing 2.4 ms (the tone map at output resolution 0.6 ms of it),
G-buffer 1.6, lighting 1.3, depth prepass 1.0, shadows 0.6, ambient occlusion
0.6, velocity 0.6. No pass repeats over the whole frame per view beyond about
0.1 ms of clears.

## Power at 30 FPS, split screen (October 20, 2026)

Whole-machine power from `tools/analysis/socpower.c`, 30 s per row, M5 Pro,
2560×1440, BG3 started from Steam with the overlay and lab mode, MetalFX
Temporal Quality, two-player split screen with lab virtual controllers, a
static camera. Rows remove one thing with a lab `skip` rule (wrong image, real
cost) or switch the upscaler with lab `scaling`. Two baselines 30 min apart
agreed within 0.2 W.

| Row | Total | GPU | Memory and fabric | CPU (machine) |
| --- | --- | --- | --- | --- |
| Baseline | 20.1 W | 8.8 | 4.4 | 4.5 |
| MetalFX Spatial instead of Temporal | 16.6 | 7.2 | 3.7 | 4.1 |
| FSR 1.0 instead of Temporal | 16.3 | 7.1 | 3.6 | 4.2 |
| Without volumetric fog and clouds | 18.1 | 8.2 | 3.7 | 4.2 |
| Without SSAO | 19.7 | 8.3 | 4.2 | 5.0 |
| Without sharpening (RCAS replay) | 19.4 | 8.4 | 4.3 | 4.5 |
| Without shadow depth, tone map LUT or SSSS | about 20.0 | | | |
| One view, Temporal | 16.6 | 7.6 | 3.9 | 3.1 |

MetalFX Temporal is the largest single cost (about 3.5 W against Spatial or FSR
at the same render size), then volumetric fog and clouds. BG3 itself used
1.9 W of CPU in split screen; the rest of the machine's CPU power came from
other applications. Skipping bloom or the outline passes broke the chain that
MetalFX follows and fell back to FSR, so those rows measure nothing useful.

## 0.3.2: Reduced Locking and Dynamic Worker Prioritization (October 22, 2026)

The same save and spot, lab mode, MetalFX Spatial Quality (853×960 → 1280×1440
per view), two-player split screen with lab virtual controllers, 30 FPS cap,
charger, two 40 s windows per run (`socpower` for the machine, `procpower` for
BG3's process). The game was restarted for each run. Settings had changed
since October 20 (GPU about 4.4 W against 7.2 W then), so only these rows
compare with each other.

| Run | Total | GPU | CPU (machine) | BG3 CPU time | BG3 CPU power |
| --- | --- | --- | --- | --- | --- |
| 0.3.2, Reduced Locking off | 15.3–15.7 W | 4.1–4.3 | 5.8–6.0 | 75–76% | 2.19–2.29 W |
| 0.3.2, Reduced Locking on | 16.6–16.8 W | 4.8 | 6.4 | 69% | 2.32–2.33 W |
| Before 0.3.2 (Dynamic Worker Prioritization) | 15.7–16.3 W | 4.5–4.7 | 5.7–6.3 | 85–94% | 2.14–2.27 W |
| 0.3.2, Reduced Locking off, repeated | (other applications busy) | | | 76–78% | 2.40–2.48 W |

At this load neither change moves BG3's CPU power beyond the 0.2–0.3 W
between runs of the same build. Reduced Locking cut BG3's CPU time by about 8%,
and Dynamic Worker Prioritization raised it (background workers on the
Performance cores) without saving power here; the upstream measurements of
both (about −0.7 W and −0.9 W) are at 60 fps in a CPU-heavier scene. Machine
totals vary by about 1 W between restarts, mostly in GPU power.

## Tools

- `tools/analysis/socpower.c [seconds] [samples] [--json]`: whole-machine power by
  subsystem (CPU, GPU, DRAM, memory controller and fabric, display engines, other)
  from IOReport's energy counters, like powermetrics but without root
  (`clang -fblocks -O2 tools/analysis/socpower.c -framework CoreFoundation -o socpower`).
  Counters other than the GPU's advance about every 2 s: use 2 s samples or more.
  On an M5 Pro the idle machine draws about 1.8 W, half of it memory and fabric.

## Metal 4 submission against 0.4.1 (October 26)

Synthetic, `bridge-handshake-sim` on an M5 Pro. Since the 0.4.1 merge it
tracks, enqueues and commits its stand-in BG3 buffers as the runtime does and
checks whether each Metal 4 submission ran between the work its buffer encoded
before and after it. Three bridges: this fork's, the same with
`BG3MFX_METAL4_ORDER=0` (submission at once, as before October 19), and 0.4.1's
(`GPUResources.mm` from upstream, its commit hook set as its runtime sets it).
Two or three full runs each, plus repeats of single scenarios.

| Scenario | This fork | Order off | 0.4.1 |
| --- | --- | --- | --- |
| baseline, recreate, swap-recreate, abandon-old | in order | in order | in order |
| recreate-late (F2 enqueued behind F1, F1 committed 1 s late) | F2 waits about 1 s for F1, as the GPU queue order requires | stall, misordered | F2 waits up to 4 s, misordered |
| swap-same (commits reversed on one queue) | in order | 4 s stall, misordered | misordered |
| abandon-same (a dropped buffer ahead of later ones) | in order | 4 s stall | in order |
| late-cross-queue, late-3.5 (a buffer committed 1 or 3.5 s late on another queue) | in order | stall | misordered |
| late-4.5 | in order | 4 s stall, misordered | misordered |
| two-bridges (Temporal-like and a recreated FG-like bridge, commits reversed) | in order in 30 of 30 runs alone | 4 s stall, misordered (10 of 10) | misordered (10 of 10) |

Misordered: a Metal 4 submission ran before the work its BG3 buffer encoded
ahead of it, so MetalFX would read inputs BG3 had not written yet. A Metal 4
queue wait gives up after about 4 s without an error and runs the work; the
4 s stalls end there. The 0.4.1 bridge takes an uncommitted earlier buffer for
a dropped one and submits its work without the wait, which misorders every
buffer committed late or out of encoding order.

Not explained yet: at the end of a full run (after every other scenario, 11 s
apart), two-bridges stalled 4 s on this fork's bridge in two of five runs and
on 0.4.1's in one of two: the BG3 buffers were committed at once but only
scheduled after 4 s, so both Metal 4 waits gave up first. It did not stall in
30 runs alone, after the three late scenarios alone (twice), in a full run
without the stall hook, or in three full runs with 0.3 s between scenarios.
Nothing in the submission order explains a buffer that is not scheduled, so
something else on the machine may have held the GPU.

## Port onto 0.5.0 (November 2)

0.5.0 installs every part of the runtime as a feature through root
(`BG3MFX_FEATURE_<NAME>=1`) and splits `Trace.mm` into metal-hooks and
metalfx's renderer (`MetalFXRenderer.mm`). This fork's changes moved with it:

- Split-screen upscaling, per-view Frame Generation, the RCAS replay
  (sharpening) and lab mode are in `MetalFXRenderer.mm`, with their helpers
  under `src/features/metalfx/` (`split-screen/`, `sharpening/`, `lab/`). The
  split-screen fog fix is upstream's `viewportFogDescriptor`, also applied
  without dynamic resolution.
- The window rebind click fix is the `window-rebind-click` feature.
- metal-hooks keeps this fork's ordered Metal 4 submission (its commit hook
  commits through `BG3MFXMetal4Commit`, and it hooks `-enqueue`), its lookup of
  originals the Steam overlay exchanged, and gains renderer extension points:
  compute constants and every texture slot recorded, each dispatch's grid,
  blit texture copies, frame presents, compute passes with a descriptor and
  bound setBytes data.
- `tools/launch/steam-launch.sh` sets `BG3MFX_ENABLE=1` and the player
  launcher's feature flags plus `BG3MFX_FEATURE_WINDOW_REBIND_CLICK=1`.

Synthetic (M5 Pro, macOS 27): `make test` (every upstream regression plus
`split-screen-upscale-smoke` with and without Frame Generation,
`split-screen-fog-smoke`, `lab-smoke`, the sharpening-off runs and
`runtime-smoke` with the overlay's exchanged methods) and `make test-python`
pass. Not yet checked live.
