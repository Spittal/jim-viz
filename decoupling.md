# Decoupling & Tool Encapsulation Instructions

This document provides technical instructions for eliminating lingering "global" concepts and state from `Engine`, encapsulating them into their respective tools according to **Principle 1** ("Tools are decoupled. Mappings are the only connections") and **Principle 5** ("Do expensive work only when something consumes it").

---

## Context & Principles

In `jim-viz`:
1. **Tools are decoupled.** Every input, modulator, camera, palette, generator, and effect is a self-contained tool. No tool reads another tool's data unless connected via an explicit mapping.
2. **Parameters live with their tool.** Every tweakable knob belongs to its tool.
3. **Beta software rules:** Clean code outranks resilience. No migration shims, no legacy fallbacks, no defensive parsing. Update files in `Content/Scenes` and `Content/Presets` directly if schemas change.
4. **Validation:** `scripts/check.sh` must pass cleanly before reporting work as complete.

---

## Scope of Work

### 1. Encapsulate Audio In (`audioSettings`, `audio`, `meters`)

#### Current Problem
- `Engine` directly owns:
  - `let audio = AudioCapture()`
  - `let audioSettings: ParamBank`
  - `let meters = AudioMeters()`
  - `private var savedAudioSettings: [String: Float]`
- In `Engine.uiTick()`, audio analysis parameters (`range`, `release`, `sensitivity`, `gate` from `AudioParams.defs`) are diffed every tick and persisted into `UserDefaults.standard` under `"audio.params"`.
- In `AudioDevice.swift`, these knobs are rendered via `KnobGrid(params: engine.audioSettings.params)` and a comment states: `"Analysis settings are global, not per scene, so they aren't mapping targets."`
- This violates the core design principle that parameters live with their tool and can be modulated via mappings.

#### Target Architecture
1. **Introduce `AudioState`:**
   - Similar to `ClockState` (in `Sources/JimViz/Clock/ClockState.swift`), create an `AudioState` class that encapsulates the UI state of the Audio In tool:
     - Owns or interfaces with `AudioCapture` and `AudioMeters`.
     - Exposes source selection (`.rekordbox`, `.systemAudio`, `.input(uid)`), channel pair selection, status text, and health.
   - Decouple `AudioDevice.swift` from direct `engine.audio` and `engine.meters` properties.
2. **Move Audio In Parameters to Tool Parameters:**
   - Audio In's knobs (`range`, `release`, `sensitivity`, `gate`) should be treated like any other tool parameters in the scene chain (`InputDevice.audio`), making them inspectable, mappable targets (e.g. `audio.range`, `audio.sensitivity`).
   - Remove `savedAudioSettings` and the `UserDefaults` diffing in `Engine.uiTick()`.
   - Update `SceneFile` / `RenderScene` if input parameters are serialized with the tool.
3. **Render Thread & Analyzer:**
   - In `RenderLoop.swift`, pass the scene's audio parameters to `analyzer.process(ring:dt:settings:)` when `hasAudioInput` is true.

---

### 2. Encapsulate MIDI Learning

#### Current Problem
- `Engine` manages MIDI learn state for individual input devices:
  - `var learningMIDI: String?` (holds the chain key of the device currently learning, e.g. `"midi"` or `"midi2"`)
  - `func startLearningMIDI(_ key: String)`
  - `func stopLearningMIDI()`
  - `func handleMIDI(_ msg: MIDIMessage)`
- In `InputDevices.swift`, the MIDI device panel binds directly to `engine.learningMIDI`.

#### Target Architecture
1. **Move Learning State into `MIDIEngine` or `MIDIInputRuntime`:**
   - `MIDIEngine` should track which `MIDIInputRuntime` (if any) is currently learning controls.
   - Alternatively, let each `MIDIInputRuntime` maintain an `isLearning` flag, with `MIDIEngine` coordinating so only one learns at a time.
2. **Simplify `Engine`:**
   - `Engine` should only act as a router: when a `MIDIMessage` arrives on main thread via `midi.onMessage`, `Engine` forwards the message to the active scene's MIDI inputs (`scene.midiInputs`).
   - Remove `learningMIDI`, `startLearningMIDI`, and `stopLearningMIDI` from `Engine`.

---

### 3. Decouple the Signal Bus (`SignalFrame`)

#### Current Problem
- `SignalFrame` in `Sources/JimViz/Engine/Signals.swift` acts as a monolithic global broadcast struct containing fields for:
  - Global time: `time`, `dt`
  - Clock: `beat`, `bpm`
  - Audio bands: `bass`, `mid`, `high`, `level`, `kick`, `snare`, `hat`
- In `RenderLoop.swift`, `clock.advance()` and audio analyzer features populate `SignalFrame` unconditionally on every frame, even when a scene has no Clock or no Audio In.
- Modulators (LFOs) in `ModulatorRuntime.swift` read `f.beat` directly when `rSynced` is true.

#### Target Architecture
1. **Scope Signal Production:**
   - When `primaryScene.hasAudioInput == false`, audio signals on `SignalFrame` must stay neutral (`muteAudio()`).
   - When `primaryScene.hasClock == false`, clock signals must fall back to neutral/zero rather than broadcasting the clock's internal beat.
2. **Explicit IO Connections for Modulators:**
   - When an LFO is mapped to `clock.sync` (`StreamInput(key: "mod.<id>.sync", kind: .clock)`), it consumes clock phase explicitly through that connection. Ensure LFO sync phase is governed strictly by the presence of that mapping.

---

### 4. On-Demand Device Lifecycle

#### Current Problem
- In `Engine.init()`, all hardware subsystems are started unconditionally on launch:
  ```swift
  self?.audio.start()
  self?.midi.start()
  self?.webcams.start()
  self?.activateWebcams()
  self?.output.start()
  ```
- If a scene contains no Webcams, the webcam manager should not keep camera hardware active.
- If a scene contains no Audio In, the audio capture tap should idle or stop processing buffers.

#### Target Architecture
- Align with **Principle 5** ("Do expensive work only when something consumes it"):
  - When loading or switching scenes, inspect `scene.hasAudioInput`, `scene.webcams`, `scene.midiInputs`.
  - Start audio capture only when Audio In is in the active scene (or transition).
  - Activate camera sessions only when a Webcam device is in the active scene.
  - Put hardware subsystems to sleep or release sessions when unmapped/unused.

---

## Step-by-Step Implementation Plan

1. **Step 1: Audio In Encapsulation**
   - Create `Sources/JimViz/Audio/AudioState.swift`.
   - Move `AudioCapture`, `AudioMeters`, and audio settings orchestration into `AudioState`.
   - Update `Sources/JimViz/UI/AudioDevice.swift` to bind to `AudioState`.
   - Remove `savedAudioSettings` and `UserDefaults` polling from `Engine.uiTick()`.
   - Run `scripts/check.sh`.

2. **Step 2: MIDI Learning Encapsulation**
   - Move `learningMIDI` state into `MIDIEngine` (in `Sources/JimViz/MIDI/MIDIEngine.swift`).
   - Update `Sources/JimViz/UI/InputDevices.swift` (`MIDIInputDevice`) to use `engine.midi.learningDeviceKey` or `input.isLearning`.
   - Remove `learningMIDI` methods from `Engine.swift`.
   - Run `scripts/check.sh`.

3. **Step 3: Signal Frame & Tool Inactivity Auditing**
   - In `RenderLoop.swift`, ensure `SignalFrame` mutes audio when `!needsAudio` and zeros clock when `!hasClock`.
   - Audit `ModulatorRuntime.swift` to ensure synced modulation requires active `clock.sync` mapping.
   - Run `scripts/check.sh`.

4. **Step 4: Verification & Self-Check**
   - Add verification to `Sources/JimViz/Engine/SelfCheck.swift` confirming that tools start decoupled and inactive when not in the chain.
   - Run `scripts/check.sh` to ensure headless rendering, shader compilation, and onset detection pass.
