# Lab mode

Lab mode is an investigation aid for finding which BG3 shader draws a visible
effect. It is off unless `BG3MFX_LAB` names a directory, and it works in both the
quiet and the diagnostic runtime.

```sh
BG3MFX_LAB="$PWD/build/lab" python3 tools/bg3mfx.py launch
```

While the game runs, the runtime rereads `<dir>/control.txt` at most four times
a second, at frame presentation:

- `skip <text>`: every draw or compute dispatch whose pipeline name contains
  `<text>` is dropped. Render pipelines are named `vertexFunction|fragmentFunction`,
  compute pipelines by their kernel. Rules apply from the next pipeline bind.
- `watch <text>`: calls of matching pipelines also record, in the census, every
  bound texture (identity, size, format, label), the viewport and scissor, and for
  dispatches the grid. Identities tell whether two views share a texture.
- `census <name>`: when the name changes, the next frame's render and compute
  encoders are written to `<dir>/census-<name>.json`, in encoding order, with
  their labels, color and depth targets, and per-shader call counts (skipped
  calls are marked `[skipped]`). A census already named when the game starts is
  not recorded.

`<dir>/status.json` reports the generation, skip rules and census name the game
applied. `tools/lab.py` writes the control file, waits for that confirmation,
summarizes a census, and takes screenshots once BG3 is the frontmost app
(`probe NAME TEXT...` applies a rule set and takes one shot).

Skipping pipelines that the MetalFX integration recognizes (TAA, the color
passes it follows, FSR, CombineUI) changes what the upscalers receive; skip them
only with Upscaling Type Off or FSR. Lab mode does not alter any game file.
`make test` covers it with `lab-smoke` on both runtimes (synthetic only).
