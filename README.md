# jim-viz

Reactive, generative low-poly 3D visuals for DJ sets, native on macOS (Swift + Metal).

## Run

```sh
scripts/run.sh                      # debug build, edits to Content/ hot-reload live
scripts/run.sh --release            # optimized build
scripts/run.sh --output fullscreen  # start fullscreen on the projector (or main screen)
scripts/check.sh /tmp/snaps         # compile shaders, render scenes with test audio, score onsets
scripts/bundle.sh                   # build build/JimViz.app
scripts/fetch-depth-model.sh        # once: the ~50 MB model behind the Webcam's Depth output
```

No Xcode needed; the Command Line Tools are enough. Shaders compile at runtime.

The bundled app copies `Content/` to `~/Library/Application Support/jim-viz/Content` on first
launch and reads from there. `scripts/run.sh` reads the repo's `Content/` directly.

## Rekordbox Library & Live Metadata

`jim-viz` reads Rekordbox's local library (`~/Library/Pioneer/rekordbox/master.db`) and WAL journal in real time:

- **Zero configuration & zero memory hacks:** Decrypts Rekordbox's SQLCipher database using native macOS cryptography, with WAL replay so newly played tracks show up immediately.
- **Track changes** drive the `track.change` signal. (The Now Playing card is hidden for now:
  Rekordbox only writes history after a track has played for a while, so it lags.)
- **Tempo Guide:** The track's analyzed BPM guides the audio tempo tracker, allowing instant lock-on to the correct tempo without half-time/double-time confusion.

## Audio

The **Audio In** device (left of the chain) picks the source:

- **Rekordbox** (default) taps Rekordbox's output directly with a Core Audio process tap.
  No virtual audio driver is needed. If Rekordbox plays to a multichannel interface like the
  DDJ-FLX4, jim-viz captures that device's channels and listens to one pair: 1–2 (master)
  by default, so the headphone cue never drives the visuals. It reconnects by itself when
  Rekordbox starts, quits, or changes output device.
- **System Audio** listens to everything the Mac plays. Handy for testing with any player.
- **Input Device** listens to a hardware input, such as a line-in from a mixer.

**Permission:** macOS asks once for audio capture. Running via `scripts/run.sh`, the
permission belongs to your terminal (or editor) app; the bundled app asks for itself. If the
status says it hears silence while music plays, enable it in System Settings › Privacy &
Security › Screen & System Audio Recording.

Levels are auto-gained: each band is 1 at its recent peak and 0 at `range` dB below, so
mappings behave the same whether the set is quiet or loud. Knobs:

| Knob | Effect |
|---|---|
| range | dB below the recent peak that reads as 0. Smaller is punchier. |
| release | How fast levels fall, in seconds. |
| sensitivity | Onset detection sensitivity for kick, snare and hat. |
| gate | Below this level (dBFS) everything reads 0. |

Settings are global and saved between launches.

## Using it

- **Scenes** are listed in the sidebar. `⌘]` / `⌘[` step through them.
- **Knobs**: drag up/down, hold Shift for fine control, double-click to reset.
  A cyan outer arc shows how far mappings can push a knob; the cyan dot is its live value.
- **Composing**: the browser under the scene list holds tools (Audio In, Orbit Camera,
  Palette, Low Poly, each effect). Open a tool to see its presets. Drag a tool or a preset
  onto the chain, double-click it, or hover and click `+`. A tool on its own loads defaults.
  Camera, palette, input and generator each have one slot, so dropping one anywhere on the
  chain replaces it. Effects insert where the accent line shows. Drag an effect by its header
  to reorder it; `×` or right-click removes it. The orange dot turns an effect off.
- **New scene** (`⌘N` or `+` above the scene list): Audio In, Clock, the Orbit camera and Ember
  palette, no generator, no effects.
- **Palette**: click a swatch to edit it with the system color panel. Its knobs, **red**,
  **green**, **blue** (gains), **hue**, **saturation** and **brightness**, adjust every colour
  and are mappable; the gradient shows the result. Switching palette presets keeps them.
- **Save** with `⌘S` (writes knob values, palette and chain back to the scene JSON).
  Editing the JSON on disk reloads it immediately and replaces unsaved knob changes.
- **Tempo & Clock**: the **Clock** device in the chain has the BPM, Tap, beat position (click
  it to snap to the downbeat) and clock mode (`Auto`, `Audio`, `Manual`). The sliders button in its
  header, next to the ×, opens latency compensation and the audio tempo search range. Typing a BPM or tapping switches to
  manual tempo. Clock settings are global; the device just puts them, and the clock's outputs,
  in the scene. `⌥⌘T` taps and `⌥⌘D` snaps from anywhere.
- **Clock Fallback**: Auto mode follows audio tempo analysis when a steady beat is heard,
  and falls back seamlessly to the manual clock when audio is quiet or ambiguous. Transitions glide
  phase smoothly with no visual jumps or skips.
- **Transitions**: Every scene change automatically executes a smooth 300ms GPU crossfade.
- **Fold a device** by double-clicking its header; double-click the strip to unfold it.
- **Select a device** by clicking it (its header lights up). The inspector on the right
  (`⌥⌘0`, or the sidebar button at the top right) shows its outputs and mappings.
  See [Mappings](#mappings).
- **Duplicate a scene** with `⌘D` or right-click → Duplicate. The copy includes unsaved edits.
- **Rename a scene** by double-clicking it in the list, right-click → Rename,
  or Scene ▸ Rename Scene. Return saves, Esc cancels. The file is renamed to match
  (`Big Drop` → `big-drop.json`); unsaved edits stay unsaved.
- **Output**: toolbar menu, or `⇧⌘F` to toggle fullscreen on the projector. Esc on the output
  turns it off. If the projector disconnects, output drops to a window and returns to
  fullscreen when it reconnects.

## Scenes and presets

A scene is a device chain, processed left to right:

```
INPUTS (AUDIO IN  CLOCK  MIDI  WEBCAM …) | MODULATION (LFO  LFO …) | CAMERA  PALETTE  GENERATOR | EFFECT → EFFECT → …
```

Inputs are signal sources: one Audio In, one Clock, and any number of MIDI Inputs and Webcams.
**Modulation** holds LFOs, any number; right-click one to move it left or right. The section
only shows once a scene has an LFO.

Like Ableton, the browser separates **tools** (device types) from **presets** (saved settings
for one tool):

| Kind | Tools | Presets in |
|---|---|---|
| Input | Audio In, Clock | — |
| Modulation | LFO | `Content/Presets/modulation/lfo/` |
| Camera | Orbit Camera | `Content/Presets/camera/orbit/` |
| Palette | Palette | `Content/Presets/palette/palette/` |
| Generator | one per `Content/Shaders/generators/*.metal` (Low Poly) | `Content/Presets/generator/<shader>/` |
| Effect | one per `Content/Shaders/effects/*.metal` | `Content/Presets/effect/<shader>/` |

A preset is `{ "name": "Drift", "params": { … } }`. Palette presets add `colors`; generator
presets add `shape` and `detail`. Drop a new file in a tool's folder and it shows up.

Adding a preset copies its values into the scene, so editing a scene never changes the preset
or any other scene. Structural edits are held in memory (the title bar says "Edited") until `⌘S`.

`Content/Scenes/*.json`. Only `name` is required:

```json
{
  "name": "Ico Shatter",
  "inputs": [
    { "type": "audio" },
    { "type": "clock" }
  ],
  "modulators": [{ "type": "lfo", "id": "lfo", "params": { "shape": 0, "sync": 1, "rate": 6 } }],
  "camera": { "type": "orbit", "preset": "orbit", "params": { "distance": 6, "orbitSpeed": 0.2 } },
  "palette": { "preset": "ember", "colors": ["#07040F", "#3B0A5C", "#B5177A", "#FF5E5B", "#FFD8A8"] },
  "generator": { "type": "lowpoly", "preset": "ico-shatter", "shape": "icosphere", "detail": 2,
                 "params": { "explode": 0.1, "wire": 0.6 } },
  "effects": [
    { "effect": "feedback", "id": "feedback", "preset": "tunnel", "params": { "amount": 0.82 } },
    { "effect": "glow", "id": "glow" }
  ],
  "mappings": [
    { "source": "audio.kick", "target": "generator.explode", "amount": 0.25, "curve": 2 },
    { "source": "mod.lfo.out", "target": "generator.twist", "amount": 0.2 },
    { "source": "midi.midi.cc-31-7", "target": "post.glow.amount", "amount": 1 }
  ]
}
```

- **inputs**: in chain order. Without `audio`, audio signals read 0; without `clock`, clock
  outputs aren't available (the clock still runs, so synced LFOs keep time).
- **preset** fields only label where a device came from; the values in the scene are what render.
- **generator.params**: unlisted knobs use the shader's defaults.
- **modulators**: LFOs. `id` names them in sources (`mod.<id>.out`) and targets (`mod.<id>.<param>`).
- **effects**: applied in order. `id` names the effect in mapping targets (`post.<id>.<param>`).
- **palette**: darkest first. Shaders sample it as a gradient.
- Generator **shape**: `icosphere`, `torus`, `plane`, `cube`, `shards`, `field` (a 16:9 sheet for webcam depth). **detail**: 0–6.
- Mappings to a device the scene doesn't have stay inactive until you add it.
- Every scene change crossfades over 300 ms.

### Mappings

Tools in the chain have **outputs**, 0–1 signals that can be mapped to any knob in the
scene, including another LFO's knobs. Mappings belong to the scene and save with it.

Select a device to see its outputs in the inspector. Click `+` next to an output and then
click a knob (Shift-click to map several; Esc to finish), or pick a knob from the output's
`→` menu. You can also drag an output onto a knob, or right-click a knob → Map. Each mapping
shows under its output with its settings, and under **Mapped Into** on the device it drives.
With nothing selected, the inspector lists every mapping in the scene. Each mapping has:

- **Amount**, −100% to +100% of the knob's range, added on top of where you set the knob.
  Negative pushes it down.
- **Smooth**, a glide time so hits become swells.
- **Curve** (under "Curve…"): below 1 boosts small values, above 1 keeps only strong ones.

`value = knob + amount × curve(signal) × knob range`

| Output | Source key |
|---|---|
| Audio In: Bass, Mid, High, Level | `audio.bass` `audio.mid` `audio.high` `audio.level` (auto-gained) |
| Audio In: Kick, Snare, Hat | `audio.kick` `audio.snare` `audio.hat` (1 on a hit, then decaying) |
| Audio In: Intensity | `audio.intensity` (loudness, bass and hits, smoothed over ~1.5 s: rises into drops, falls in breakdowns) |
| Clock: Pulse | `clock.pulse` (1 on each beat, decaying) |
| Clock: Beat, Bar and Phrase ramps | `clock.beat` `clock.bar` `clock.phrase` (over 1, 4 and 32 beats) |
| Clock: Track Change | `clock.track` (1 when Rekordbox loads a new track, fading over a few beats) |
| LFO: Out | `mod.<id>.out` |
| MIDI Input: each learned control | `midi.<id>.cc-31-7`, `midi.<id>.note-11-1`, `midi.<id>.pb-0-1` (kind, number, channel) |
| Camera: Orbit Angle | `camera.angle` (position around the orbit) |

The **LFO** has shape (sine, triangle, saw up/down, square, random, noise), sync (synced
rates from 1/16 to 16 bars, or free in Hz), phase and depth.

Generators and effects have no outputs yet: their values are computed on the GPU.

**MIDI** controllers are inputs too. The browser lists **MIDI Input** with each connected
controller under it; add one (or the bare tool, to listen to every device). It starts in
**Learn Controls** mode: each new control you move becomes one of its outputs (DDJ-FLX4 controls
show by name). Turn Learn off, select the device, and map its controls like any other output.
Notes read 1 while held. For a fader that sweeps a knob's whole range, set the knob to its
minimum and the amount to 100% (−100% to invert). Right-click a control in the inspector to forget it.

Mappings whose source or target isn't in the chain wait, dimmed, until it is.

**Copy and paste** mappings between scenes from the inspector's clipboard menu, or with
`⌥⌘C` and `⌥⌘V`. Right-click a mapping to copy just that one. Pasting skips mappings the
scene already has.

Targets: `generator.<param>`, `camera.<param>`, `palette.<param>`, `post.<id>.<param>`, `mod.<id>.<param>`,
`webcam.<id>.<param>`, and stream inputs such as `generator.bgVideo`, `generator.spec` and
`generator.pal` (see [Streams](#streams-video-spectrum-palette)).
In JSON a mapping has `amount`, and optionally `smooth` (seconds), `curve` and `enabled`.
A MIDI Input is `{ "type": "midi", "id": "midi", "device": "DDJ-FLX4", "controls": ["cc-31-7"] }`;
leave out `device` to listen to every controller.

### Streams: video, spectrum, palette

Devices are only connected through mappings: nothing reaches a shader that you haven't mapped
into it. IO comes in four kinds, and each only connects to its own:

- **Value** outputs (0–1, like Kick or an LFO) map onto knobs.
- **Video** outputs (a Webcam's Video and Depth) map onto video inputs.
- **Spectrum**: Audio In's Spectrum output (128 bands, 30 Hz to 16 kHz) maps onto spectrum
  inputs, such as the generator's Spectrum, which the **spectrum** knob pushes the mesh out by.
- **Palette**: the Palette's Colours output maps onto palette inputs, such as the generator's
  Palette and Palette Map's.

Each stream input takes one stream; mapping another replaces it. Unmapped, video and spectrum
inputs read 0 and a palette input is a grey ramp, black to white. Nothing connects itself: a
new generator, effect or webcam starts with its inputs and outputs unmapped.

A **Webcam** input (Inputs → Webcam, with each connected camera listed under it) has a video
output, the camera feed after its processing knobs, previewed in the device. Every knob is mappable:

- **zoom**, **rotate**, **pan x/y**, **mirror** (Off, Flip for the selfie view, Fold, Quad)
- **warp** with **warp scale** and **warp speed**, a slow swirling displacement
- **exposure**, **contrast**, **saturation**, **edges** (outline), **posterize**

It also has two value outputs, **Motion** (how much the picture is changing) and **Brightness**.

Its second video output, **Depth**, is depth guessed from the plain camera image by a neural
network (Depth Anything V2 Small, run through Core ML on the Neural Engine at ~30 fps): grey,
white = near. It's relative, not in metres, and framed by the same zoom/rotate/pan/mirror/warp
knobs as the video so the two line up. The model runs only while Depth is mapped somewhere;
then the device shows a depth preview with its rate. Three more knobs shape it:

- **depth smooth** eases out the model's frame-to-frame flicker (higher is calmer but laggier)
- **depth contrast** bends the range; above 1 pushes the background back
- **depth floor** flattens everything farther than it to zero, so only near things rise

Fetch the model once with `scripts/fetch-depth-model.sh` (Apache-2.0, from Apple's Hugging
Face). It lives in `~/Library/Application Support/jim-viz/Models`, outside the repo;
`scripts/bundle.sh` copies it into the app. Depth needs a lit scene: in the dark or under
strobes the model has little to go on.

Besides Palette and Spectrum, the **generator** has three video inputs:

- **Background**, behind the mesh. **video bg** sets how much shows.
- **Texture**, painted onto the faces. **video tex** sets how much; **video map** picks how:
  Faces (the default: every polygon shows the whole video, sliced onto it), Screen (the mesh
  is a window onto the video), Shards (each face shows its own patch of that view), Sphere
  (wrapped around the object), Normal (by face direction, kaleidoscopic) or Front (projected
  flat from the front, like Depth, so a webcam's video sits on its own depth relief).
  **video scale** zooms the mapping; **video scatter** turns and shifts each face's copy in
  Faces mode.
- **video tint** recolours both through the palette by brightness.
- **Depth** raises the mesh toward the camera where the video is white, along each vertex's
  normal, projected from the front. **depth** is how far; **depth cut** hides faces stretched
  across a depth edge, so a person stands free of the wall instead of joined to it by a skirt.
  Made for the **field** shape, a 16:9 sheet facing the camera; see the Depth Field scene
  (`05-depth-field.json`), which maps a webcam's Depth into it and its video onto it in Front
  mode. The camera's **swing** knob keeps it in front: above 0 the camera swings that many
  degrees either side instead of orbiting all the way round.

Map a stream like any output: click `+` on it in the inspector and then a socket, use its `→`
menu, or drag it onto a socket. The sockets only appear on the device while a stream of their
kind is waiting to be mapped (dragging one counts); the device's inspector always lists them
under Inputs, with a menu to pick or clear each one.

Shaders declare inputs the way they declare knobs with `// @param`:
`// @video name Label`, `// @spectrum name Label` or `// @palette name Label`. They take
texture slots in declaration order, generators from `texture(0)` up and effects from
`texture(2)` up; `hasInput(f, n)` says whether the input at `texture(n)` is connected. So an
effect can take video, a spectrum or a palette by adding one line. Webcam processing lives in `Content/Shaders/inputs/webcam.metal`; add a
`// @param` there and the Webcam gets a knob. The first webcam asks for camera access.

In JSON a webcam is `{ "type": "webcam", "id": "webcam", "device": "FaceTime HD Camera" }`
(leave out `device` for the default camera). A stream mapping is just a source and target:
`{ "source": "webcam.webcam.video", "target": "generator.bgVideo" }`,
`{ "source": "webcam.webcam.depth", "target": "generator.depthVideo" }`,
`{ "source": "audio.spectrum", "target": "generator.spec" }`,
`{ "source": "palette.colors", "target": "generator.pal" }`.

## Writing shaders

Effects live in `Content/Shaders/effects/`. Each file declares its knobs in comments and
gets a `Params` struct generated from them:

```metal
// @param amount 0.5 0 1      name default min max
// @param steps 4 1 16 int
// @param mode 0 0 2 int Soft,Hard,Off   int knobs can name their steps
// @palette pal Palette                  an input: map the Palette's Colours into it

fragment float4 effect(FXOut in [[stage_in]],
                       texture2d<float> src [[texture(0)]],   // previous effect's output
                       texture2d<float> prev [[texture(1)]],  // last frame's output
                       texture2d<float> pal [[texture(2)]],   // first declared input
                       constant Frame& f [[buffer(0)]],       // resolution, time, dt
                       constant Params& p [[buffer(1)]]) {
    float4 c = src.sample(linearClamp, in.uv);
    return float4(mix(c.rgb, palette(pal, luma(c.rgb)), p.amount), c.a);
}
```

`Frame` has only resolution, time and dt: audio levels, hits and the clock reach a shader
by mapping an output (Audio In · Kick, Clock · Pulse) onto one of its knobs. Declare
`// @spectrum spec Spectrum` and read it with `spectrum(spec, u)`, 30 Hz at u=0 to 16 kHz at
u=1. The low-poly generator's `spectrum` knob pushes geometry out by its Spectrum input;
`spectrumMode` picks height, per-face, angle or radius mapping.

Add `// @history self` to receive the effect's own previous output in `prev` (used by
`feedback`). Helpers such as noise, rotation and palette lookup are in `common.metal`.
Save the file and it recompiles; errors appear in the status bar and the last working
version keeps running.

## Layout

```
Sources/JimViz/
  App/      app entry, menus, projector output windows
  Audio/    Core Audio taps, FFT analysis, onset detection
  Engine/   params, signals and mappings, clock, scene files, hot reload, self-check
  Render/   Metal renderer, render thread, mesh generators, shader compiler
  UI/       SwiftUI control window, knobs, device chain
Content/
  Scenes/   scene JSON
  Presets/  tool presets: camera/, palette/, generator/, effect/
  Shaders/  common.metal, generators/, effects/
```
