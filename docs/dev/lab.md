# Lab mode

Lab mode is an investigation aid for live BG3 rendering work: finding which
shader draws a visible effect, what it reads, what each pass costs, and why a
renderer integration does or does not engage. It is off unless `BG3MFX_LAB`
names a directory, and it works in both the quiet and the diagnostic runtime.

```sh
BG3MFX_LAB="$PWD/build/evidence/lab" python3 tools/launch/bg3mfx.py launch
```

Do not rebuild `build/bin/libBG3MetalFX.dylib` while a game started from it runs;
check `pgrep -f "MacOS/Baldur"` first.

## Control file

While the game runs, the runtime rereads `<dir>/control.txt` at most four times
a second, at frame presentation. Each line is one rule; rules not present in the
file are cleared. Render pipelines are named `vertexFunction|fragmentFunction`,
compute pipelines by their kernel; `<text>` matches any part of that name.

| Line | Effect |
| --- | --- |
| `skip <text>` | Drops every draw or dispatch of matching pipelines, from the next pipeline bind. |
| `watch <text>` | Calls of matching pipelines also record, in the census, every bound texture (identity, size, format, label), constant buffer and `setBytes` payload, viewport, scissor and, for dispatches, the grid. |
| `census <name>` | When the name changes, the next frame's render and compute encoders go to `census-<name>.json` in encoding order: labels, color/depth targets with identities, per-shader call counts (`[skipped]` marked), `setBytes` payloads, and vertex layouts of watched render pipelines. A census already named at launch is not recorded. |
| `profile <name>` | A census whose render and compute passes also carry GPU timestamps at stage boundaries. Once the GPU has finished the frame, `profile-<name>.json` lists each pass with its `gpuMs`. Passes overlap on the GPU, so add `serialize` for exclusive per-pass times. |
| `serialize` | Chains every render and compute encoder with a fence, so each starts after the previous one finished. It changes performance; use it for measurement and race checks only. |
| `poke <text> <slot> <offset> <value>` | Rebinds a copy of the constants at `<slot>` with a 4-byte value at `<offset>` for matching calls only, then restores the original binding. `<slot>` is a compute index or `vertex:N`/`fragment:N`; a value `iN` writes an integer, otherwise a float. |
| `dump <tag> <text> <slot> [#N]` | Copies the texture bound at `<slot>` (or `color0`, the render target) of the Nth matching call of a frame (default the first) right after its encoder ends, to `dump-<tag>.raw` with a JSON description. Each tag is captured once. |
| `dumpbuf <tag> <text> <slot> <length> [#N]` | The same for a buffer or `setBytes` binding; `<slot>` as for `poke`. |
| `scaling <1/2/3>` | Renders new command buffers as FSR, MetalFX Spatial or Temporal regardless of the menu, for same-scene comparisons (FSR and Spatial share the render size; Temporal needs the menu's TAA setup). |
| `sharpen <0/1>` | Turns BG3's RCAS sharpening of MetalFX output off or on. |
| `pad <N> [buttons]`, `pad <N> stick <left/right> <x> <y>` | Virtual game controller `N` (1–4), connected while it has a line, holding the named buttons (`a b x y lb rb lt rt l3 r3 menu options home up down left right`) and stick positions (−1 to 1). See below. |

## Virtual controllers

`pad` lines let lab mode test controller paths, such as two-player split screen,
without physical controllers. Each pad is a simulated GameController controller
(`+[GCController controllerWithExtendedGamepad]`) presented as an Xbox
controller: it is added to `+[GCController controllers]` and announced with
`GCControllerDidConnectNotification`, and button and stick changes call the
element and profile change handlers as real input does; pressing `menu` also
calls the controller's pause handler, where BG3 takes its Menu button
(`options` is the View button). Removing a pad's lines
disconnects it. The timeline records connections and BG3's first queries.
`tools/launch/lab.py pad` presses, holds and releases buttons and tilts sticks
(see its help). Changes apply at the next control-file read, so a press lasts at
least a quarter of a second.

## Output files

| File | Contents |
| --- | --- |
| `status.json` | The rule generation, skip/watch/poke rules, census name and `scaling` the game applied, and the virtual controllers as of the previous change (the player index BG3 gave each, whether it installed a change handler, held buttons). |
| `perf.json` | About once a second: presented frames per second, command buffers per second, `gpuMsPerFrame` and `gpuBusy` from BG3's command buffers, and `metal4MsPerFrame`, MetalFX Temporal's own GPU time on its Metal 4 queue. BG3's command buffers wait for that queue, so with Temporal their time includes the wait; use `metal4MsPerFrame` or a serialized profile for real costs. `metal4Reordered` counts Metal 4 submissions that reached their queue in another order than they were encoded in (see [architecture](architecture.md)). |
| `census-*.json`, `profile-*.json` | As above; a profile also records MetalFX's own GPU time per frame from the latest `perf.json`. |
| `dump-*.raw`, `dump-*.json` | Raw texels or bytes; the JSON gives size, pixel format, bytes per row, viewport and the capturing call. |
| `input-log.jsonl` | A timeline of AppKit input events (with the posting process for synthetic events), game controller changes, window and display changes (window frame, screen backing scale, Metal layer drawable size), cursor warps, `CGEventPost` calls with their game call sites, bg3mfx menu events, and upscaling pipeline events: scene capture per view, the pass chain from TAA to FSR, blit copies, lookups at FSR and native fallbacks (the first 300 of each kind per split-screen view, then every 300th with its count), and virtual controller events. |

## Tools

`tools/launch/lab.py` writes the control file, waits for the `status.json`
confirmation, summarizes a census pass by pass, and takes screenshots once BG3
is the frontmost app (`probe NAME TEXT...` applies a rule set and takes one
shot; `rules NAME LINE...` applies exact control lines and takes two).
`pad N press|hold|release|stick|connect|disconnect` drives the virtual
controllers; other commands keep `watch` and `pad` lines. `profile-summary NAME`
adds up a profile by category (shadows, depth prepass, G-buffer, velocity,
lighting, fog, post-processing, TAA and upscaling, UI, from BG3's material and
shader names; approximate), lists the most expensive passes, and the passes
that cover the whole target more than once a frame (in split screen, work that
should cover one view).

For comparing shaders offline, with extracted data kept in the ignored `build/`
directory and never distributed:

- `tools/reference/metallib_extract.py LIB list|extract`: functions of a `.metallib` as
  AIR bitcode; disassemble with `xcrun clang -S -emit-llvm -x ir NAME.air`.
- `tools/reference/metallib_reflect.m` (build with `xcrun clang -fobjc-arc -framework
  Foundation -framework Metal`): bindings and constant-buffer members of
  kernels, or of a render pair with `--render VERTEX FRAGMENT PIXELFORMAT`.
- `tools/reference/lspk.py PAK list|extract`: Larian LSPK v18 archives, such as the
  Windows `EngineShaders.pak` (downloaded by the license holder).
- `tools/reference/bshd_spirv.py FILE.bshd OUTDIR`: SPIR-V modules from Vulkan `.bshd`
  shader files, for `spirv-cross`.

## Cautions

Skipping or poking pipelines that the MetalFX integration recognizes (TAA, the
color passes it follows, FSR, RCAS, CombineUI) changes what the upscalers
receive. Lab mode never alters any game file. `make test` covers the control
file, census, dumps, pokes, serialization, the profiler and two virtual
controllers with `lab-smoke` on both runtimes (synthetic only).
