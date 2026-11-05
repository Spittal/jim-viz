# jim-viz — Vision

A native macOS app for reactive, generative 3D visuals during DJ sets played in Rekordbox.
It renders low-poly abstract scenes with heavy post-processing, driven by the music and
sequenced like a timeline.

Scope note: jim-viz is a focused reactive generative viz app, not a full VJ platform.
TouchDesigner is the long-term destination for bigger shows; jim-viz may later feed it
frames over Syphon.

## Setup it targets

- One MacBook (M4 Pro) running Rekordbox (latest) and jim-viz at the same time.
- Pioneer DDJ-FLX4 controller over USB.
- One projector over HDMI, 1920x1080 at 60fps minimum.
- Laptop screen shows the jim-viz control window; the projector shows the output fullscreen.

## Stack

- Swift + Metal for rendering, SwiftUI for the control UI, built with Swift Package Manager.
  No Xcode required.
- Shaders compiled at runtime from source, which gives hot reload for free.
- Rendering on its own thread, paced by the output display, so UI work never drops frames.
- CoreMIDI, AVFoundation (webcam), Core Audio process taps (Rekordbox audio),
  SQLite / CommonCrypto (Rekordbox library database).

## UI style

Native macOS chrome (window, toolbar, sidebar, menus, shortcuts, dark mode) so it feels
familiar. The working area borrows from Ableton Live: dense dark-gray panels, a horizontal
"device chain" of generator, camera and effects with knobs, a flashing beat indicator,
and a status bar for errors.

## Signal sources (layered for resilience)

Every source reports its own health. Beat-based modulation uses the best healthy clock and
falls back automatically, keeping beat phase continuous across switches.

| Priority | Source | Gives | Breaks when |
|---|---|---|---|
| 1 | Audio analysis of the Rekordbox process | Bands, onsets, loudness, estimated BPM/beat | Never (always on) |
| 2 | Rekordbox library database (`master.db`) | Live track history, artist, title, key, BPM, artwork, cues | Never (read-only SQLite decryption) |
| 3 | Internal clock with tap tempo | Tempo, beat, phase | Never |
| — | Generic MIDI (DDJ-FLX4 default map) | Crossfader, faders, EQ, filter, play/cue, pads | Controller unplugged |
| — | Other MIDI controllers (Ableton-style learn) | Manual override and live tweaking | — |
| — | Webcam | Texture for geometry/skybox, motion and brightness as signals | — |
| — | LFOs | Free-running or beat-synced modulation | Never |

Rekordbox's own LINK button stays off, because it makes Rekordbox follow the Link tempo and
changes how you DJ.

## Core model

- **Parameters.** Every tweakable value (geometry, camera, material, palette, post) is a named
  parameter with a range. Shader parameters are declared in the shader file itself.
- **Mappings.** Tools expose outputs (audio bands and hits, clock ramps and pulse, LFOs,
  camera angle); a mapping routes an output to any knob in the scene, with amount, curve and
  smoothing. MIDI controllers are input devices whose learned controls are outputs. Mappings belong to the scene.
- **Scenes.** A device chain composed from the browser, left to right: inputs (Audio In,
  Clock, MIDI controllers), then modulation (any number of LFOs), then a camera,
  palette and one generator, then any number of effects. Plus mappings. The browser
  lists tools (device types) with their presets, like Ableton; a preset's values are copied in.
- **Transitions.** Two scenes render at once and blend: crossfade, wipe, feedback melt, or
  parameter morph, timed in beats.
- **Sequences.** A JSON timeline of cues. Each cue is a trigger (bar count, phrase change,
  track change, energy threshold, wall-clock time) plus an action (go to scene, with transition).
- **Manual override.** MIDI can jump to a scene, hold the current one, nudge params, and hand
  control back to the sequence.

## Aesthetic

Low-poly first: flat-shaded procedural meshes, vertex displacement, shattering, instancing,
wireframes, glitchy feedback post-processing. The generator system stays open so
raymarching, attractors and other experiments can be added as new generator types later.

## Milestones

1. ✅ **Output and render loop.** Control window plus fullscreen projector window, one low-poly
   generator, a post chain, hot-reloaded scene JSON and shaders, internal clock.
2. ✅ **Audio.** Tap Rekordbox audio; bands, onsets, loudness, spectrum wired into mappings.
   Audio-derived BPM estimation and clock fallback.
3. ✅ **Generic MIDI & Controller Support.** CoreMIDI input with hotplug reconnect; CC, note and
   pitch bend; DDJ-FLX4 control names.
4. ✅ **Scenes and transitions.** Scenes composed from a tool/preset browser (inputs, cameras,
   palettes, generators, effects) with drag and drop; 300 ms crossfade on every scene switch.
5. ✅ **Mappings.** Tool outputs mapped to any knob from a right-hand inspector, with amount,
   smoothing and curve; LFO and MIDI Input tools (learned controls become outputs); copy/paste mappings and
   duplicate scenes.
6. ✅ **Webcam.** Typed IO: value and video. A Webcam input with a video output and processing
   knobs (zoom, rotate, pan, mirror, warp, colour, edges, posterize); shaders declare video
   inputs (`// @video`), and the generator's Background and Texture take it; motion and
   brightness as value outputs.
7. **Sequencer & Automation.** Timeline cues, scene sequence scheduling, manual override.

Later: Syphon output (bridge to TouchDesigner), video files, more generators, Rekordbox
library metadata.
