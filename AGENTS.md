# AGENTS.md

Guidance for AI agents working on Jim Viz. Read this first, then `README.md` for how things
work.

## What this is

A native macOS app (Swift + Metal + SwiftUI) for reactive, generative, low-poly 3D visuals. It is a focused reactive viz app, not a full VJ platform.

**Stack:**
- Swift with Metal for rendering and SwiftUI for the controls, built with Swift Package
  Manager.
- Shaders compile at runtime from source, which gives hot reload.
- System frameworks: Core Audio process taps for audio, CoreMIDI for MIDI, AVFoundation for
  webcams, and Core ML for depth estimation.

## Design principles

These come from the user and outrank convenience. When a change would bend one of them,
stop and ask.

### 1. Tools are decoupled. Mappings are the only connections.

Every input, modulator, camera, palette, generator and effect is a self-contained **tool**.
No tool reads another tool's data unless the user has mapped it there.

- **No hidden coupling.** A shader can't read audio, clock or palette data on its own.
  `Frame` holds only `resolution`, `time`, `dt` and the video-input bitmask. Kick, beat,
  spectrum and colours reach a shader only through a mapping.
- **Nothing connects itself.** A new generator, effect or webcam starts with all its inputs
  unmapped. Don't add auto-connect or "helpful" default wiring. (One was added and then
  removed at the user's request.)
- **If a tool needs something new from another tool**, add an output on the source and an
  input on the consumer, then map them. Don't reach across.
- **Unmapped inputs fall back to neutral values:** value and spectrum read 0, video reads
  black, and palette reads a plain black-to-white grey ramp.
- **Parameters live with their tool.**
  - Every tweakable value is a named parameter with a range.
  - Shader parameters are declared in the shader file itself, with `// @param`.
  - Mappings belong to the scene.

### 2. Typed IO

Outputs and inputs have a kind, and a kind only connects to the same kind
(`IOKind` in `Engine/StreamIO.swift`). `Engine.addMapping` rejects mismatched kinds.

| Kind | Example outputs | Consumed by |
|---|---|---|
| value (0–1) | Audio In · Kick, Audio In · Drums Stem, Audio In · Pulse, LFO, MIDI control, Webcam · Motion | any knob, with amount, curve and smooth |
| video | Webcam · Video, Webcam · Depth | `// @video name Label` inputs |
| spectrum | Audio In · Spectrum, Drums/Bass/Vocals/Other Spectrum (128 log bins) | `// @spectrum name Label` inputs |
| palette | Palette · Colours | `// @palette name Label` inputs |
| audio | Audio In · Audio Out | nothing yet |
| clock | Audio In · Sync | LFO · Sync, `// @clock name Label` inputs (the shader's `rate` knobs follow the beat) |
| trigger | Audio In · On Beat/Bar/Phrase, Camera · On Cut | Cutter · Cut, Video · Jump, LFO · Reset, Audio In · First Beat |
| stmap | Lens · ST Map (Nuke convention: s, t in red, green; t bottom to top) | Camera · Lens, which reprojects the rendered picture before the effects |

- A value mapping is additive: `value = base ± amount × curve(signal) × span`, with amount 0–100%
  and an invert toggle for the minus.
- A trigger input also takes value outputs: it fires each time the value rises past ½ (re-arming below ¼), so an LFO, kick or MIDI pad can fire it. Any number can be mapped onto one; trigger mappings have no settings. Triggers don't map onto knobs. Don't add trigger + threshold knobs; declare a `TriggerInput`.
- A stream input (video, spectrum or palette) takes one stream; mapping another replaces it.
- **Add a new kind when the data isn't a 0–1 scalar**; don't squeeze it into a value.
- Shaders declare their inputs in comments, and the inputs appear as sockets.

### 3. Left to right is signal flow

The device chain reads like an Ableton track, and the picture is built left to right:

```
Inputs (Audio In, MIDI, Webcam) → Modulation (LFOs) → Camera → Lens → Palette → Generator → Effects…
```

- Inputs and modulators produce signals.
- The generator renders the scene.
- Each effect processes the previous effect's output (`src`), in chain order. Reordering
  effects changes the image.
- Chain keys: `audio`, `midi.<id>`, `webcam.<id>`, `video.<id>`, `picture.<id>`,
  `mod.<id>`, `camera`, `lens`, `palette` (the first palette) and `palette.<id>` (the rest),
  `generator` (the first generator) and `generator.<id>` (the rest), `post.<id>`.
- **A scene** is one such chain plus its mappings, saved as JSON in the library's `Scenes` folder (see Storage).
- **Switching scenes** renders the outgoing and incoming scenes at once and blends them.
  Today that's a crossfade.

### 4. Ableton-inspired, native macOS

- **Use native macOS chrome:** window, toolbar, sidebar, menus, shortcuts and dark mode, so it
  feels familiar.
- **Model the working area on Ableton Live:**
  - dense dark-grey device panels with knobs;
  - a browser that lists **tools** with their **presets** underneath (a preset's values are
    copied in);
  - drag and drop into the chain;
  - double-click a device header to fold it.
- **Selecting a device** highlights it, and the right-hand inspector shows its outputs,
  inputs and mappings.
- **Keep mapping settings in the inspector,** not on the device panels. A device's inputs
  and outputs show as tags only in its IO columns, behind the **IO** toggle in its header
  (inputs left, outputs right, each scrolling vertically). Don't put IO tags among the knobs.
- **Device settings** go in a popover button in the device header, next to the close X.
- **No empty-state "+ drop here" placeholders.**
- **Errors go in the status bar.** For example, a shader that fails to compile shows its
  error there, and the last working version keeps running.

### 5. Performance is key

This runs live on a projector. Dropped frames
are bugs.

- **The render thread is separate from the UI,** paced by the output display's
  `CADisplayLink`.
  - The render thread reads `@ObservationIgnored` mirrors; locks guard snapshots.
  - Don't make the render thread wait on SwiftUI or `@Observable` state.
- **Do expensive work only when something consumes it.** For example, the depth model runs
  only while Webcam · Depth is mapped somewhere.
  - The exception is the stem separator, which runs whenever a scene's Audio In is rendered:
    Kick, Snare and Hat are found in its drum stem, and Audio In's lamps and Intensity use them.
- **Keep per-frame allocations and CPU↔GPU syncs out of the hot path.** Use rotating or
  triple-buffered textures, as the spectrum and palette already do.
- **Release builds use `-Ounchecked`.** Measure (ms per frame, fps) when adding anything heavy.

### 6. Experimental and abstract

The aesthetic reference is Autechre and Aphex Twin visuals: weird, glitchy and abstract.

- **Low-poly comes first:** flat-shaded procedural meshes, vertex displacement, shattering,
  instancing, wireframes, per-face video and glitchy feedback post-processing.
- **Keep the generator system open** so raymarching, attractors and other experiments can be
  added as new generator types.
- **Expose things as mappable knobs** rather than hard-coding them. Where it makes sense,
  tools should have outputs too, so more can be experimented with.

## Working rules

- **Beta software: clean code outranks resilience.**
  - The app is in beta: no backward compatibility, no migration shims, no legacy fallbacks,
    no versioned tools or resilient schemas.
  - The JSON format does not need to be resilient or forgiving. If a scene or preset is
    missing expected fields, has an invalid enum/shape, or fails to parse, fail fast with an
    error (e.g. "JSON invalid" or "invalid shape") rather than silently falling back to a default.
  - Work lost is fine; prioritize clean, simple, unencumbered Swift and Metal code over
    defensive parsing or edge-case handling.
  - When a format or tool changes, update the files in the library's `Scenes`, `Presets`
    and `Playlists` directly without adding compatibility shims. They're the user's files and
    aren't in git, so say which ones you changed.
- **Never commit or push unless asked.** The remote is `git@github.com:Spittal/jim-viz.git`,
  branch `main`.
- **Don't add behaviour that wasn't asked for.** If you think something extra is needed,
  propose it. If you did add something, say so clearly in your report.
- **Respect the user's scene edits.** The user edits and deletes scenes themselves. If files
  vanish or change, ask before restoring or rewriting them.
- **Say what you verified and what you didn't.** For example: "tested with a synthetic
  frame, not a real camera".

## Storage

- **Library: `~/Library/Application Support/jim-viz`** holds the user's `Scenes`,
  `Presets`, `Playlists`, `Videos` and `Pictures`, plus the depth model in `Models`. It's not
  in git, and the app creates the folders empty on first launch.
  - `JIMVIZ_LIBRARY` overrides it.
- **Content: the repo's `Content/`** holds `Shaders`, `Maps` and `Models` (BeatNet's weights for beat tracking, StemgenRT's for stem separation), which are code and ship
  with the app.
  - `scripts/run.sh` points `JIMVIZ_CONTENT` at it, so shaders hot-reload.
  - The bundled app reads its own copy in `Contents/Resources/Content`.
- **Caches: `~/Library/Caches/jim-viz`** holds the compiled depth model.
- **The self-check never touches the real library.** It runs on a scratch copy and writes
  its own fixture scenes and preset, so it passes with an empty library.

## Build, run, verify

Only the Command Line Tools are installed, no Xcode. SwiftPM builds the app, and shaders
compile at runtime.

```sh
scripts/run.sh [--release] [--output fullscreen]  # repo shaders, your library
scripts/check.sh [/tmp/snaps]   # headless self-check on a scratch copy of your library
scripts/bundle.sh [1.2.3]       # build/Jim Viz.app
scripts/release.sh 1.2.3 [--publish]  # check, bundle, build/jim-viz-1.2.3.dmg; --publish tags and releases
scripts/fetch-depth-model.sh    # once: Core ML depth model (~50 MB)
```

- **`scripts/check.sh` must pass before you report work as done.**
  - Add checks for new rules to `Engine/SelfCheck.swift`, such as type safety or a new
    tool starting unmapped.
  - Snapshots can differ between runs because the camera orbit accumulates across the
    check's renders, so compare colours and geometry, not exact pixels.
- **CI (`.github/workflows/ci.yml`)** runs `scripts/release.sh <latest tag's version>` on
  every push to main and pull request, and keeps the disk image as an artifact. It never
  publishes; releases are made locally with `--publish`.
- **Hot reload covers shaders and scene/preset JSON only.** New Swift code needs a relaunch.
- **Screenshots of the running app:** find the window ID (the owner name is `jim-viz`),
  then `screencapture -x -o -l <id>`.

## Gotchas

- **Audio-capture permission belongs to whichever app ran `scripts/run.sh`** (Zed or
  Terminal), and that app may need a restart after the permission is granted.
- **With a Core Audio process tap,** the tap's channels are the *last* channels of the
  aggregate device's input.
- **GPU history textures start uninitialised.** Guard against NaN in feedback and smoothing
  shaders.
- **Core ML compiled model:** cached in `~/Library/Caches/jim-viz`. Loading it from a fresh
  temp path costs about 5 s every launch.
- **Shader `Frame` layout** must match `FrameUniforms` in `Render/MathUtil.swift`.
