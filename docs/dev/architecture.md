# Rendering architecture

## User-visible settings

`NativeMenu.mm` adds a persistent Show Metal HUD checkbox at the top of General
and appends MetalFX Spatial and MetalFX Temporal to BG3's existing Upscaling Type
combo. The native Off and AMD FSR 1.0 entries remain owned by BG3. The native
quality combo supplies Ultra Quality, Quality, Balanced, and Performance.

BG3's settings code accepts only Off and FSR as upscaling types. Selecting a
MetalFX type temporarily invokes BG3's FSR setup callback to retain its quality
and render-resolution behavior, then restores the custom menu value and stores
the selected type separately. Startup and Options → Back use the same setup.
The quality state is independent of the custom type. This bridge is
build-specific and guarded by the executable's Mach-O UUID.

Spatial keeps the native anti-aliasing option enabled unless Frame Generation is
on. While Temporal or Frame Generation is on, the menu selects the Anti-Aliasing
entry labelled "TAA" through its own callback, dims the control, and saves the
player's previous choice (`BG3MFXSavedAntiAliasing`) to restore when neither is
on. Temporal keeps BG3's TAA
input production but skips the TAA draw only on exact targets previously seen
feeding the upscaling stage. Inventory and other auxiliary views retain native
TAA. A newly discovered upscaled target keeps native AA for its discovery frame;
Temporal history is reset before and after that frame so its filtered input is
not accumulated with later raw jittered inputs. Weak target identities avoid
retaining obsolete textures or matching a recycled address. Its output is
written where the game's upscaling result is expected, and the separate AA
control is disabled while Temporal is selected.

## Renderer flow

`Trace.mm` contains the Metal interception layer used by both runtime builds. It
tracks each command buffer's selected mode and associates exact BG3 textures
through TAA, post-processing, and the native FSR stage. Unknown or mismatched
resources fail closed instead of guessing from dimensions. Native FSR dispatches
are skipped only for an active MetalFX mode. Off and FSR retain BG3's callbacks
and native rendering.

`Sharpening.mm` keeps the player's Sharpness setting for MetalFX. BG3's chain
is `FSR_Tonemap` (c / (1 + max c)), FSR and `FSR_RCAS`, which sharpens in that
space, leaves hair (its hair mask) unsharpened and writes linear HDR
(c / (1 − max c)). The MetalFX result is written to a pooled texture, mapped
into FSR's space in a half-float texture (rounded up, since the undo magnifies
rounding near white and BG3's RG11B10 targets round toward zero), and BG3's
own `FSR_RCAS` dispatch is replayed with its pipeline, constants, hair mask
and grid into the final target. Compute constant bindings are tracked in
MetalFX mode for this. `BG3MFX_METALFX_SHARPENING=0` keeps the unsharpened
output.

`SpatialUpscaler.mm` copies BG3's linear HDR scene color from RG11B10Float into
RGBA16Float, runs MetalFX Spatial in HDR mode, and copies the result into BG3's
FSR output target. The input is after bloom and color grading but before
`FSR_Tonemap`; BG3's tone mapping and UI composition remain downstream.

`Trace.mm` captures HDR scene color, device depth, motion, camera constants, and
BG3's original jitter at the TAA stage. It copies current color into the skipped
TAA output and tracks that color through native bloom, color grading, and outline
passes. `TemporalUpscaler.mm` receives the final tracked HDR color before
`FSR_Tonemap`, alongside the earlier scene inputs. MetalFX reads BG3's
RG11B10Float color, Depth32Float_Stencil8 depth and RG16Float motion in place
and writes straight into BG3's final upscaler target when that target has the
usage MetalFX requires (BG3's does); otherwise it writes a pooled output that is
copied into the target. The current motion scale is −1, −1 and depth is reversed, based
on inspected BG3 shader conventions. History is reset when the selected scaling
mode changes or input resources become invalid. `NativeJitter.mm` substitutes
Halton (2,3) samples at three guarded native loads: projection, camera constants,
and velocity history. Only Temporal views with an enabled native FSR stage use
14/18/24/32 phases for Ultra Quality/Quality/Balanced/Performance. A frame-local
choice keeps all three consumers consistent during settings changes. BG3's
previous projection/jitter storage remains responsible for motion compensation;
the shared eight-sample table is unchanged for other views and modes.
`BG3MFXApplyNativeJitter` converts BG3's sample displacement to MetalFX's
image displacement: X is negated and Y retains the native Y-up sign. The old
adapter supplied the opposite displacement in both framebuffer axes, preventing
correct temporal reconstruction. The analytic reconstruction test and captured
depth registration establish this conversion; see the
[quality diagnosis](validation/temporal-jitter-diagnosis.md).

Temporal uses `MTL4FXTemporalScaler` on devices reporting `supportsMetal4FX:`;
other devices retain `MTLFXTemporalScaler`. A dedicated Metal 4 queue waits on
an event signaled after BG3 produces the scaler inputs, then signals another
event that BG3's original Metal 3 buffer waits on before consuming the output.
Per-submission residency and feedback-owned resources preserve GPU lifetimes.
This does not convert BG3's renderer or presentation to Metal 4. See the
[Metal 4 audit](validation/metal4-temporal.md) for the API/model distinction and
validation limits.

`MetalFXPipeline.mm` owns only the MetalFX Spatial/Temporal scaler objects,
resource checks, output allocation, scaler encoding, and its cross-API GPU event bridge. It has no BG3 menu,
frame presentation, patching, or distribution responsibilities.

## Split screen

BG3 renders each split-screen view into its own rectangle of shared full-size
textures, with that view's viewport and Viewport constants (`g_ViewportScale`,
`g_ViewportOffset`, size, minimum, index), then runs FSR and RCAS over the
whole frame once per view.

`SplitScreenFog.mm` fixes the volumetric fog composite. BG3 pairs
`DeferredFog_*_PS` with `DefaultVS`, which passes the fullscreen triangle's
view-relative texCoord through, while the fragment shader indexes the fog volume
(all views side by side) with render-target UVs, as `PPDefaultVS` provides for
every other full-screen pass. Each view therefore sampled fog belonging to
another part of the screen. When BG3 creates that pipeline, bg3mfx substitutes
its own vertex function applying the view's scale and offset (bound at vertex
buffer 9 for every full-screen pass); in a single view it is an identity.
`BG3MFX_SPLIT_SCREEN_FOG=0` restores BG3's pairing.

MetalFX upscales each view on its own (`ViewRegions.mm`). The TAA capture
records the view rectangle from the Viewport constants; at each view's FSR
dispatch, color, depth and motion are cropped into view-sized pooled textures,
upscaled by a Temporal scaler of that view's own (own history; Spatial shares
one per size) and placed into the view's rectangle of the output, which keeps
either view from sampling the other at the seam. With sharpening, both views
share one intermediate per frame, so the last view's whole-frame RCAS replay
sharpens both. Between bloom and colour grading BG3 copies scene color with
blits in split screen (`copyFromTexture:sourceSlice:sourceLevel:toTexture:…`);
the scene association follows such copies like the recognized color passes.
Frame Generation pairs whole frames only and stays unpaired in split screen.

## BG3 fixes outside rendering

`NativeFixes.mm` intercepts two imported functions at verified call sites of
the supported build only; every other caller gets the original function.

- Idle waits: BG3's frame limiter (`ls::GameClock::CapFrame`, which also paces
  the server thread) and its job scheduler's idle loop
  (`ls::WorkerThreadScheduler::DoWork`) wait by calling `pthread_yield_np` in a
  loop, keeping about three cores busy at a 30 FPS cap. There a short spin is
  followed by short sleeps. `BG3MFX_IDLE_WAIT=0` restores the spinning.
- Window rebind click: after `cocoa::CocoaWindow::BindSurface` swaps the
  window's content view (as when the render resolution changes), BG3 posts a
  left mouse click through the HID event tap to focus the new view. The click
  switched BG3's UI from controller to mouse and keyboard and could press
  whatever was under the hidden cursor. While BG3 is active, bg3mfx makes the
  new view first responder instead. `BG3MFX_KEEP_REBIND_CLICK=1` keeps the click.

Both install after the native menu's build guard and check that each call site
still calls the expected import stub.

## Frame Generation

Frame Generation is the "MetalFX Frame Generation" checkbox (item `0x7f02`),
added right after the upscaling controls only on supported devices and saved
as `BG3MFXFrameGenerationEnabled`. It combines with every Upscaling Type, which
is back to BG3's Off and FSR plus MetalFX Spatial and Temporal (values 0–3).
Startup migrates earlier settings: Upscaling Type values 4 (Temporal + Frame
Generation) and 5 (Spatial + Frame Generation) become Temporal or Spatial with
the checkbox set, and the older Temporal-only checkbox carries over. Clearing
the checkbox releases the interpolator and presentation worker.

Frame Generation pairs frames using the depth, motion and camera constants
captured at BG3's TAA pass, validated as for Temporal, so the scene must be
followed from there to `CombineUI`. Temporal attaches them to its output.
Every other type keeps native TAA, whose output seeds the chain: MetalFX
Spatial attaches them to its output, BG3's FSR and RCAS dispatches forward them
from input to output, and with Off, BG3's CAS (FidelityFX sharpening) dispatch
after tone mapping forwards them from its input to its output. The
recognized color passes and tone mapping then carry them to `CombineUI`. Jitter
comes from BG3's constants, so the native eight-phase sequence is described as
is. Frames that reach `CombineUI` without these inputs (menus, loading screens,
native-FSR fallback frames) are presented unpaired, and pairing resumes with the
next frame that has them. With `BG3MFX_TRACE_TEMPORAL_CHAIN=1`, the diagnostic
runtime records the recent pass chain in each `frameGenerationNoScene` event.
A live trace (October 13) showed Off + Frame Generation losing the scene at
CAS, which reads the tone-mapped RGB10A2 scene and writes the one `CombineUI`
composes; with the CAS forward, Off + Frame Generation works live.

Presentation follows Apple's present-thread model. While Frame Generation is on, a
`CAMetalLayer nextDrawable` hook gives BG3 stand-in drawables backed by three
pooled textures; BG3 renders, composes UI, and "presents" into them unchanged,
and blocks like a real drawable when all three are in flight. BG3 presents before
encoding `CombineUI`, so the stand-in present is resolved at `commit`, which also
signals a shared event. The worker in `FrameInterpolation.*` acquires real
drawables itself and waits for that event on the GPU. It spaces the generated
and real images about half of BG3's smoothed frame interval apart:

| Case | Presentation |
| --- | --- |
| VSync on | `presentDrawable:afterMinimumDuration:`, the frame's whole refreshes (at least two) split between the images |
| VSync off, a frame spans at least two refreshes | The same |
| VSync off, faster | Generated image when its copy finishes, a half-interval wait on the worker, then the real image; uncapped and tearing |

`afterMinimumDuration:` rounds up to whole refreshes, so each minimum is set
just under its count of refreshes: half the interval rounded up past the frame
time and let the presenter fall behind. It would also cap the vsync-off fast
case. On the paced paths (the first two rows) BG3 gets one stand-in instead of
its two or three, whatever its double/triple buffering: the display paces the
pairs, and extra stand-ins only queue frames. The fast vsync-off path keeps
BG3's own buffering. The frame log records BG3's requested buffering and the
stand-ins allowed. The refresh interval is read on the main thread from the
layer's window. The stand-in is released when the real copy completes, before
any wait, and the worker skips the wait when BG3's next frame is already
queued. Frames without a generated image are presented at once. Only the generated scene goes through an extra
`CombineUI` pass. The worker never blocks BG3's or Metal's threads. Devices
without Metal 4 FX use the Metal 3 effect. This implementation still needs
displayed/pacing validation and does not establish HDR support. See the
[frame-generation record](validation/frame-generation.md).

## Hook overhead

Every intercepted Metal call runs on BG3's render thread, which issues about
12,000 draws per frame. A `sample` of the quiet runtime showed about half of
that thread inside the hooks, in Temporal and in Frame Generation alike, when
binds built strings and dictionaries and every call took a global lock to find
the original method. Hooks now keep one `BG3MFXEncoderState` per encoder with
fixed binding slots. Pipelines are classified once, at creation, and draws with
unrecognized pipelines go straight to Metal. Original-method lookups are cached
per thread. An unrecognized draw's only effect, dropping a scene association for
the encoder's target, is applied once at `endEncoding`. A synthetic run of
20,000 draws and 80,000 binds took 5.5 ms without hooks, 50.2 ms with the
original hooks, and 7.2 ms after the first rewrite. In the live game the hooks'
own share of the render thread fell from 52-54% to 14-22%. A second round caches
the current encoder's state per thread (refreshed at encoder creation, cleared at
`endEncoding`). It also holds bound buffers, textures and the pipeline without
retaining them, since the encoder of a retained-references command buffer keeps
them alive. That halved the remaining synthetic overhead (about 4.5 ms to
2.3 ms per 20,000 draws). Encoder classes already hooked skip re-hooking, which
otherwise took the global lock about 25 times per new encoder. A third round
makes the per-call hooks take `self` and object arguments as non-owning, so ARC
does not retain and release them around each call to the original method. It
also keeps `setBytes` data in a lazy side table, so each encoder's state owns
nothing in its binding table and is free to destroy. Synthetic overhead for 150
encoders and about 20,000 draws went from about 1.9 ms (round 2) to about
0.9 ms. Measured live on
the quiet runtime before round 3, with the game in the foreground (samples
taken while BG3 is in the background measure its background frame throttle,
`GameClock::CapFrame`, instead): about 16-17% of the render thread. Diagnostic builds still inspect every draw,
so use the quiet runtime (with `MTL_HUD_LOG_ENABLED=1` and `sample`) for
performance comparisons.

## GPU resource reuse

`GPUResources.*` provides pooled textures, returned on command-buffer
completion, and a reusable Metal 4 bridge with recycled allocators, command
buffers, events and a persistent residency set. Spatial, Temporal and frame
interpolation intermediates come from these pools, so steady-state frames
allocate no textures and create no Metal 4 submission objects.

Temporal scalers are cached per input/output size. Creating one takes tens of
milliseconds, and on macOS 27.0.1 MetalFX never deallocates a Temporal scaler
whose output is 1512 px tall or less, through either the Metal 3 or Metal 4 API.
Each keeps an `ANEServicesThread` and about 28 MB, or about 200 MB after
encoding. Taller outputs, Spatial scalers and the frame interpolator are freed.
Evicting such a scaler from the cache therefore reclaims nothing. A standalone
reproduction with the full measurements is kept outside this repository for an
Apple report. A live windowed-mode drag created one per frame
until BG3 hung inside scaler creation with about 1,000 `ANEServicesThread`s
(October 13). A size with no scaler now runs BG3's native FSR until it holds for
0.3 s; the session's first scaler is created at once. The cache keeps every
settled size: its former six-entry bound evicted by `NSDictionary` key order,
which could drop the scaler just added, so a steady size recreated one every
frame (about 1,000 in 35 s live, after nine window sizes) and hung BG3 the same
way. `temporal-hook-smoke` resizes through nine sizes, returns to each, and
checks that every size creates exactly one scaler.

MetalFX consumes BG3's textures directly wherever it accepts their format and
usage, avoiding per-frame conversion passes (about 0.7 ms each for Temporal and
Frame Generation at 4K, measured with GPU timestamps). Frame Generation reads
the RGB10A2 scene in place only on macOS 27, where `requiresPrevColorTexture = NO`
lets the interpolator keep its own history; macOS 26 still copies the scene so a
retained copy can serve as the previous color. Inputs that do not qualify are
converted into pooled copies. Live, the saving is within HUD noise (about 1 fps
at 4K); it is kept because it removes passes and memory, not for frame rate.

## Failure and diagnostics

MetalFX initialization, resource, encoding, or GPU-completion failure presents
an AppKit error and closes BG3 with exit code 78. The runtime does not continue
through FSR after a failed MetalFX frame.

Frame Generation is the exception for frames it cannot reproduce: unexpected
composition bindings or scene format, camera parameters, or an interpolator or
presenter that cannot be created. It turns itself off with a notice naming the
mismatch, the selected Upscaling Type continues, and turning the checkbox off
and on again retries. Encoding and GPU failures after it starts still close BG3.

`libBG3MetalFX.dylib` is the quiet development runtime. `libBG3MetalFXTrace.dylib`
adds JSONL traces, shader reflection, and opt-in captures. Diagnostics are not
part of the rendering feature contract and are compiled out of the quiet build.
Both builds retain the interception and lifetime work required to integrate with
BG3. `tools/bg3mfx.py` supports only inspection and launch-time injection; it
does not alter the app bundle.

## Code map

- `src/NativeMenu.mm`: settings menu, custom mode persistence, HUD checkbox.
- `src/NativeFixes.*`: idle-wait and window-rebind-click fixes at verified call sites.
- `src/SplitScreenFog.*`: the split-screen volumetric fog vertex function.
- `src/Sharpening.*`: BG3's RCAS replayed on MetalFX output.
- `src/ViewRegions.*`: split-screen view crops and placement.
- `src/LabInput.*`: lab mode's input and pipeline event timeline (see [lab mode](lab.md)).
- `src/NativeJitter.*`: guarded Temporal sample selection and ARM64 preservation.
- `src/Trace.mm`: Metal hooks, exact texture association, pass replacement,
  diagnostic instrumentation.
- `src/SpatialUpscaler.*` and `src/TemporalUpscaler.*`: BG3-specific inputs,
  conversions, and destinations for each scaler.
- `src/MetalFXPipeline.*`: backend MetalFX scaler setup and encoding.
- `src/GPUResources.*`: texture pools and the reusable Metal 4 submission bridge.
- `src/FrameInterpolation.*`: frame interpolation, stand-in drawables, and the
  presentation worker.
- `tests/*_smoke.mm`: synthetic Metal pixel and hook regressions, including
  split-screen fog and per-view upscaling (`split_screen_*_smoke.mm`) and lab
  mode (`lab_smoke.mm`).
- `tools/bg3mfx.py`: guarded, bundle-preserving development launch.
- `docs/dev/validation/`: current status and dated evidence.
