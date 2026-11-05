import Foundation
import Metal
import AppKit
import AVFoundation

/// `JimViz --check [--snapshot dir]` compiles every shader, loads every scene, renders a few
/// frames of each offscreen, and exits non-zero on any error. Optionally writes PNG snapshots.
enum SelfCheck {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if args.contains("--rekordbox-test") {
            let reader = RekordboxReader()
            reader.start()
            let end = Date().addingTimeInterval(3)
            while Date() < end {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            print("isAvailable: \(reader.isAvailable)")
            print("statusText: \(reader.statusText)")
            if let t = reader.currentTrack {
                print("currentTrack: \(t.displayTitle), key: \(t.key) (\(t.camelot)), cues: \(t.cues.count), art: \(t.artworkURL?.path ?? "none")")
            } else {
                print("currentTrack is nil")
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--analyze"), i + 1 < args.count {
            let truth = args.firstIndex(of: "--truth").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            exit(analyzeFile(args[i + 1], truthPath: truth))
        }
        if let i = args.firstIndex(of: "--capture-test") {
            let src = i + 1 < args.count ? args[i + 1] : "system"
            if src.hasPrefix("pid:"), let pid = pid_t(src.dropFirst(4)) {
                captureTest(source: .rekordbox, pid: pid)
            }
            captureTest(source: AudioCapture.Source(key: src), pid: nil)
        }
        guard args.contains("--check") else { return }
        var snapshotDir: URL?
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            snapshotDir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
            try? FileManager.default.createDirectory(at: snapshotDir!, withIntermediateDirectories: true)
        }
        let audioPath = args.firstIndex(of: "--audio").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        exit(run(snapshotDir: snapshotDir, audioPath: audioPath))
    }

    /// Mono samples of an audio file, for feeding the analyzer offline.
    static func loadMono(_ path: String) -> (samples: [Float], rate: Double)? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil, let data = buf.floatChannelData else { return nil }
        let ch = Int(buf.format.channelCount)
        let out = (0..<Int(buf.frameLength)).map { i in (0..<ch).reduce(Float(0)) { $0 + data[$1][i] } / Float(ch) }
        return (out, file.processingFormat.sampleRate)
    }

    /// Plays a file through the analyzer at a simulated 60fps and reports detected onsets.
    /// With a truth file (lines of `name t1 t2 …`), scores hits within a small tolerance.
    private static func analyzeFile(_ path: String, truthPath: String?) -> Int32 {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil, let data = buf.floatChannelData else {
            print("could not read \(path)"); return 1
        }
        let rate = file.processingFormat.sampleRate
        let channels = Int(buf.format.channelCount)
        let frames = Int(buf.frameLength)
        let ring = SampleRing(capacity: 16384)
        ring.setSampleRate(rate)
        let analyzer = AudioAnalyzer()
        let tempo = AudioTempo()
        if let i = CommandLine.arguments.firstIndex(of: "--bpm-range"), i + 1 < CommandLine.arguments.count {
            let parts = CommandLine.arguments[i + 1].split(separator: "-").compactMap { Double($0) }
            if parts.count == 2 { tempo.minBPM = parts[0]; tempo.maxBPM = parts[1] }
        }
        var tempoLog: [String] = []
        var beatAt: [(Double, Double)] = [] // (time, beat) when usable
        let chunk = Int(rate / 60)
        var detected: [String: [Double]] = ["kick": [], "snare": [], "hat": []]
        var prev = AudioFeatures()
        var sums = (bass: Float(0), mid: Float(0), high: Float(0)), count = 0
        var pos = 0
        while pos < frames {
            let n = min(chunk, frames - pos)
            ring.write(frames: n) { i in
                var v: Float = 0
                for c in 0..<channels { v += data[c][pos + i] }
                return v / Float(channels)
            }
            pos += n
            analyzer.process(ring: ring, dt: 1 / 60, settings: nil)
            let f = analyzer.features
            let t = Double(pos) / rate
            if analyzer.fresh { tempo.feed(strength: analyzer.onsetStrength, active: f.active, time: t) }
            tempo.update(now: t)
            if let rd = tempo.reading(at: t) { beatAt.append((t, rd.beat)) }
            if pos / chunk % 120 == 0 {
                let st = tempo.status()
                tempoLog.append(String(format: "%.0fs %.1f (%.0f%%%@)", t, st.bpm, st.confidence * 100,
                                       tempo.reading(at: t) == nil ? ", unusable" : ""))
            }
            if f.kick > prev.kick + 0.5 { detected["kick"]!.append(t) }
            if f.snare > prev.snare + 0.5 { detected["snare"]!.append(t) }
            if f.hat > prev.hat + 0.5 { detected["hat"]!.append(t) }
            sums.bass += f.bass; sums.mid += f.mid; sums.high += f.high; count += 1
            prev = f
        }
        print(String(format: "mean levels: bass %.2f  mid %.2f  high %.2f", sums.bass / Float(count),
                     sums.mid / Float(count), sums.high / Float(count)))
        print("tempo: " + tempoLog.joined(separator: " · "))
        let finalTempo = tempo.status().bpm
        var truth: [String: [Double]] = [:]
        if let truthPath, let text = try? String(contentsOfFile: truthPath, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ")
                if let name = parts.first { truth[String(name)] = parts.dropFirst().compactMap { Double($0) } }
            }
        }
        var ok = true
        // Phase check: at each true kick (once the estimate is usable), the beat should be whole.
        if let kicks = truth["kick"], !beatAt.isEmpty {
            var errs: [Double] = []
            for k in kicks {
                guard let idx = beatAt.firstIndex(where: { $0.0 >= k }), idx > 0, beatAt[idx].0 - k < 0.02 else { continue }
                let frac = beatAt[idx].1 - beatAt[idx].1.rounded()
                errs.append(frac * 60 / finalTempo * 1000) // ms
                if CommandLine.arguments.contains("--verbose") { print(String(format: "  kick %.2fs phase error %+.0f ms", k, errs.last!)) }
            }
            if !errs.isEmpty {
                let meanAbs = errs.map(abs).reduce(0, +) / Double(errs.count)
                print(String(format: "beat phase at kicks: mean |error| %.0f ms over %d kicks", meanAbs, errs.count))
            }
        }
        if let expected = CommandLine.arguments.firstIndex(of: "--expect-bpm").flatMap({ Double(CommandLine.arguments[$0 + 1]) }) {
            let good = abs(finalTempo - expected) < 1
            print(String(format: "tempo %.2f vs expected %.1f: %@", finalTempo, expected, good ? "ok" : "FAIL"))
            if !good { ok = false }
        }
        for name in ["kick", "snare", "hat"] {
            let d = detected[name]!
            guard let t = truth[name] else {
                let gaps = zip(d.dropFirst(), d).map { $0 - $1 }.filter { $0 > 0.2 && $0 < 1.5 }.sorted()
                let median = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
                let duration = Double(frames) / rate
                print(String(format: "%@: %d hits (%.2f/s), median gap %.3f s ≈ %.1f BPM", name, d.count,
                             Double(d.count) / duration, median, median > 0 ? 60 / median : 0))
                continue
            }
            // A hit counts if detected between 10 ms before and 60 ms after the true onset.
            var used = Set<Int>()
            var hits = 0, lags: [Double] = []
            for tt in t {
                if let j = d.indices.first(where: { !used.contains($0) && d[$0] >= tt - 0.01 && d[$0] <= tt + 0.06 }) {
                    used.insert(j); hits += 1; lags.append(d[j] - tt)
                }
            }
            let recall = Double(hits) / Double(max(t.count, 1))
            let precision = Double(hits) / Double(max(d.count, 1))
            let lag = lags.isEmpty ? 0 : lags.reduce(0, +) / Double(lags.count) * 1000
            print(String(format: "%@: %d/%d found, %d false, recall %.0f%%, precision %.0f%%, mean lag %.0f ms",
                         name, hits, t.count, d.count - hits, recall * 100, precision * 100, lag))
            let falses = d.indices.filter { !used.contains($0) }.prefix(8).map { String(format: "%.2f", d[$0]) }
            if !falses.isEmpty { print("  false at: \(falses.joined(separator: " "))") }
            if name == "kick" && (recall < 0.9 || precision < 0.9) { ok = false }
        }
        return ok ? 0 : 1
    }

    /// Captures live audio for 8 seconds and prints status and levels twice a second.
    private static func captureTest(source: AudioCapture.Source, pid: pid_t?) -> Never {
        let capture = AudioCapture(source: source)
        if let pid { capture.processFilter = { $0.processPID == pid } }
        let analyzer = AudioAnalyzer()
        capture.start()
        var ticks = 0
        var kicks = 0
        var lastKick: Float = 0
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            analyzer.process(ring: capture.ring, dt: 1 / 60, settings: nil)
            let f = analyzer.features
            if f.kick > lastKick + 0.5 { kicks += 1 }
            lastKick = f.kick
            ticks += 1
            if ticks % 30 == 0 {
                let age = CFAbsoluteTimeGetCurrent() - capture.ring.lastWriteTime
                print(String(format: "[%@] %@ | pairs %d, last block %.0f ms ago, peak %.3f bass %.2f kicks %d",
                             "\(capture.health)", capture.statusText, capture.channelPairs, age * 1000,
                             capture.ring.lastBlockPeak, f.bass, kicks))
            }
            if ticks >= 480 { exit(0) }
        }
        RunLoop.main.run()
        exit(0)
    }

    /// Outputs, modulation and MIDI mappings, LFOs, copy/paste and duplicate. Nothing is saved
    /// except the duplicate, which is deleted again.
    private static func checkMappings(engine: Engine) -> String? {
        guard let url = engine.sceneURLs.first(where: { $0.lastPathComponent == "01-ico-shatter.json" }) else {
            return "test scene missing"
        }
        // Its own empty scene (camera, no generator) to paste into, so the check never
        // depends on scenes you might rename or delete.
        let emptyURL = engine.store.scenesDir.appendingPathComponent("selfcheck-empty.json")
        let empty = SceneFile(name: "Self-check Empty", inputs: [InputSpec(type: "clock")], modulators: [],
                              camera: CameraSlot(type: "orbit"), palette: PaletteSlot(colors: Tools.defaultPalette),
                              generator: nil, effects: [], mappings: [])
        do { try empty.write(to: emptyURL) } catch { return "could not write the test scene" }
        engine.store.markSeen(emptyURL)
        engine.refreshSceneList()
        engine.pasteboard = NSPasteboard(name: NSPasteboard.Name("jimviz.selfcheck"))
        defer {
            engine.pasteboard = .general
            engine.load(url, animated: false)
            try? FileManager.default.removeItem(at: emptyURL)
            engine.refreshSceneList()
        }
        engine.load(url, animated: false)
        guard let scene = engine.current else { return "scene did not load" }
        guard scene.mappings.filter({ $0.kind == .value }).count == 5, scene.mappings.allSatisfy(\.isActive) else {
            return "mappings not all active: \(scene.mappings.compactMap(\.problem))"
        }
        let keys = Set(scene.outputs.map(\.key))
        guard keys.isSuperset(of: ["audio.kick", "clock.pulse", "clock.bar", "mod.lfo.out", "camera.angle"]) else {
            return "outputs missing: \(keys.sorted())"
        }
        // Audio In's Intensity climbs while the music is loud and busy.
        guard let intensity = scene.outputs.first(where: { $0.key == "audio.intensity" }) else { return "no intensity output" }
        var loud = SignalFrame()
        loud.level = 1; loud.bass = 1; loud.kick = 1; loud.snare = 0.5
        for _ in 0..<180 { scene.modulate(loud) }
        guard intensity.value > 0.7 else { return "intensity didn't rise: \(intensity.value)" }

        // Palette inputs: hue turns red to green at +120°, brightness scales, and they're mappable.
        let green = PaletteParams.adjust(SIMD3(1, 0, 0)) { ["hue": 120, "saturation": 1, "brightness": 1][$0] ?? 1 }
        guard green.y > 0.9, green.x < 0.1, green.z < 0.1 else { return "palette hue wrong: \(green)" }
        engine.addMapping(source: "audio.kick", target: "palette.brightness")
        guard engine.current?.mappings.first(where: { $0.target == "palette.brightness" })?.isActive == true,
              engine.current?.palette.bank["brightness"]?.isModulated == true else { return "palette input not mappable" }
        engine.current?.palette.bank["hue"]?.setBase(30)
        engine.apply(.palette, "palette", preset: "ice")
        guard engine.current?.palette.bank["hue"]?.base == 30 else { return "palette inputs lost on a preset change" }

        var f = SignalFrame()
        f.beat = 8  // on a downbeat: pulse = 1, bar ramp = 0

        // Modulation adds amount × signal × range on top of the knob.
        engine.addMapping(source: "clock.pulse", target: "camera.fov")
        guard let s1 = engine.current, let fov = s1.camera["fov"],
              let m = s1.mappings.first(where: { $0.source == "clock.pulse" && $0.target == "camera.fov" }),
              m.isActive, m.amount == 0.25, fov.isModulated else { return "pulse → fov not mapped" }
        s1.modulate(f)
        guard abs(fov.live - fov.def.clamp(fov.base + 0.25 * fov.def.span)) < 0.01 else { return "modulation amount wrong: \(fov.live)" }
        m.amount = -0.1
        s1.modulate(f)
        guard abs(fov.live - fov.def.clamp(fov.base - 0.1 * fov.def.span)) < 0.01 else { return "negative amount wrong" }
        guard abs(m.contribution + 0.1) < 0.001 else { return "mapping contribution wrong: \(m.contribution)" }
        // Settings survive structural edits.
        engine.addMapping(source: "clock.bar", target: "camera.roll")
        guard engine.current?.mappings.first(where: { $0.target == "camera.fov" })?.amount == -0.1 else {
            return "mapping settings lost on rebuild"
        }

        // MIDI Input: while learning, controls moved on its device become outputs,
        // which then map like any other output.
        func cc(_ number: Int, _ value: Int, channel: Int = 7, device: String = "DDJ-FLX4") -> MIDIMessage {
            MIDIMessage(channel: channel, command: .controlChange, data1: number, data2: value, timestamp: 0, device: device)
        }
        engine.apply(.input, "midi", preset: "DDJ-FLX4")
        guard engine.learningMIDI == "midi.midi", engine.selectedDevice == "midi.midi" else { return "new MIDI input not learning" }
        engine.handleMIDI(cc(31, 127, device: "Other Controller"))
        guard engine.current?.midiInputs.first?.controls.isEmpty == true else { return "learned a control from another device" }
        engine.handleMIDI(cc(31, 127))
        engine.handleMIDI(cc(31, 120))
        guard engine.current?.midiInputs.first?.controls.count == 1,
              let fader = engine.current?.outputs.first(where: { $0.key == "midi.midi.cc-31-7" }),
              fader.name == "Crossfader" else { return "MIDI control not learned once as an output" }
        engine.learningMIDI = nil
        engine.handleMIDI(cc(19, 127))
        guard engine.current?.midiInputs.first?.controls.count == 1 else { return "learned while not learning" }
        engine.addMapping(source: "midi.midi.cc-31-7", target: "generator.explode")
        guard let s3 = engine.current, let explode = s3.generator?.bank["explode"],
              let mm = s3.mappings.first(where: { $0.source == "midi.midi.cc-31-7" }), mm.isActive else {
            return "MIDI output not mapped"
        }
        mm.amount = 1
        engine.handleMIDI(cc(31, 64))
        s3.modulate(f)
        let expected = explode.def.clamp(explode.base + 64 / 127 * explode.def.span)
        guard abs(explode.live - expected) < 0.01 else { return "MIDI value not applied: \(explode.live) vs \(expected)" }
        engine.handleMIDI(cc(31, 127, channel: 3))
        s3.modulate(f)
        guard abs(explode.live - expected) < 0.01 else { return "MIDI on another channel moved the knob" }
        engine.removeInput("midi.midi")
        guard engine.current?.mappings.first(where: { $0.source.hasPrefix("midi.") })?.problem == "Needs its MIDI Input in the chain" else {
            return "MIDI mapping not paused without its input"
        }

        // Removing a device keeps its mappings, inactive, until it comes back.
        engine.removeInput("audio")
        guard let kick = engine.current?.mappings.first(where: { $0.source == "audio.kick" }), !kick.isActive,
              engine.current?.outputs.contains(where: { $0.key.hasPrefix("audio.") }) == false else {
            return "audio mapping not paused without Audio In"
        }
        engine.apply(.input, "audio")
        guard engine.current?.mappings.first(where: { $0.source == "audio.kick" })?.isActive == true else {
            return "audio mapping not restored"
        }
        engine.apply(.input, "audio")
        guard engine.current?.inputs.map(\.id) == ["audio", "clock"] else {
            return "inputs out of order or duplicated: \(engine.current?.inputs.map(\.id) ?? [])"
        }
        engine.removeInput("clock")
        guard engine.current?.hasClock == false,
              engine.current?.mappings.first(where: { $0.source == "clock.bar" })?.problem == "Needs Clock in the chain" else {
            return "clock mapping not paused without Clock"
        }
        engine.apply(.input, "clock")
        guard engine.current?.inputs.map(\.id) == ["audio", "clock"],
              engine.current?.mappings.filter({ $0.source.hasPrefix("clock.") }).allSatisfy(\.isActive) == true else {
            return "clock not restored after Audio In"
        }

        // LFOs: unique ids, synced output, mappable knobs.
        engine.apply(.modulation, "lfo", preset: "bar-saw")
        guard let lfo2 = engine.current?.modulators.first(where: { $0.id == "lfo2" }), lfo2.id == "lfo2", lfo2.presetLabel == "Bar Saw" else {
            return "LFO preset not added as lfo2"
        }
        guard engine.current?.modulators.map(\.id) == ["lfo", "lfo2"],
              engine.current?.effects.contains(where: { $0.id == "lfo2" }) == false else {
            return "LFO not added to the Modulation section"
        }
        engine.moveModulator(id: "lfo2", by: -1)
        guard engine.current?.modulators.map(\.id) == ["lfo2", "lfo"] else { return "LFO not moved" }
        // Adding a device selects it; clicks while mapping don't move the selection.
        guard engine.selectedDevice == "mod.lfo2" else { return "new LFO not selected" }
        engine.mapSource = "mod.lfo2.out"
        engine.selectDevice("generator")
        guard engine.selectedDevice == "mod.lfo2" else { return "selection moved while mapping" }
        engine.mapSource = nil
        engine.addMapping(source: "mod.lfo2.out", target: "generator.spin")
        engine.addMapping(source: "mod.lfo.out", target: "mod.lfo2.depth")
        guard let s2 = engine.current, s2.mappings.filter({ $0.source.hasPrefix("mod.") }).allSatisfy(\.isActive) else {
            return "LFO mappings inactive"
        }
        f.beat = 2  // halfway through a one-bar saw
        s2.modulate(f)
        s2.modulate(f)
        guard let out = s2.outputs.first(where: { $0.key == "mod.lfo2.out" }),
              abs(out.value - 0.5 * (s2.modulators.first { $0.id == "lfo2" }!.bank["depth"]!.live)) < 0.02 else { return "LFO output wrong" }
        engine.removeModulator(id: "lfo2")
        guard engine.current?.mappings.first(where: { $0.source == "mod.lfo2.out" })?.isActive == false else {
            return "mapping from removed LFO still active"
        }
        guard engine.selectedDevice == nil else { return "removed device still selected" }

        // Copy and paste into an empty scene: generator targets wait for a generator.
        let count = engine.current?.mappings.count ?? 0
        engine.copyMappings()
        engine.load(emptyURL, animated: false)
        engine.pasteMappings()
        guard let pasted = engine.current?.mappings, pasted.count == count,
              pasted.first(where: { $0.target.hasPrefix("generator.") })?.isActive == false,
              pasted.first(where: { $0.target == "camera.fov" })?.isActive == true else { return "paste failed" }
        engine.pasteMappings()
        guard engine.current?.mappings.count == count else { return "pasting twice duplicated mappings" }

        // Duplicate writes a copy with the unsaved edits, leaving the original alone.
        let before = try? Data(contentsOf: emptyURL)
        engine.duplicateScene(emptyURL)
        guard let dup = engine.currentURL, dup != emptyURL else { return "duplicate not created" }
        defer { try? FileManager.default.removeItem(at: dup); engine.refreshSceneList() }
        guard let copy = try? SceneFile.load(dup), copy.name.hasSuffix("Copy"), copy.mappings?.count == count else {
            return "duplicate missing the edits"
        }

        // Rename: the name and the file both change; the scene stays loaded.
        engine.renameScene(dup, to: "Renamed Check")
        guard let renamed = engine.currentURL, renamed.lastPathComponent == "renamed-check.json",
              !FileManager.default.fileExists(atPath: dup.path), engine.current?.name == "Renamed Check",
              engine.sceneName(renamed) == "Renamed Check", (try? SceneFile.load(renamed))?.name == "Renamed Check" else {
            try? FileManager.default.removeItem(at: engine.currentURL ?? dup)
            return "rename failed"
        }
        try? FileManager.default.removeItem(at: renamed)
        guard (try? Data(contentsOf: emptyURL)) == before else { return "duplicate changed the original" }
        return nil
    }

    /// Nothing reaches a shader except through a mapping: the palette and spectrum are typed
    /// outputs, and unmapped means grey and still.
    private static func checkStreams(engine: Engine) -> String? {
        guard let url = engine.sceneURLs.first(where: { $0.lastPathComponent == "01-ico-shatter.json" }) else { return "test scene missing" }
        engine.load(url, animated: false)
        defer { engine.load(url, animated: false) }
        guard let scene = engine.current, scene.generator != nil else { return "scene did not load" }
        guard scene.streamBindings["generator.pal"]?.key == "palette.colors",
              scene.streamBindings["generator.spec"]?.key == "audio.spectrum",
              scene.streamOutputs.map(\.key) == ["audio.spectrum", "palette.colors"] else {
            return "palette and spectrum not mapped in: \(scene.streamBindings.mapValues(\.key))"
        }

        // Typed: a palette only into palette inputs, a spectrum only into spectrum inputs.
        let count = scene.mappings.count
        engine.addMapping(source: "palette.colors", target: "generator.spec")
        engine.addMapping(source: "audio.spectrum", target: "generator.spin")
        engine.addMapping(source: "audio.kick", target: "generator.pal")
        guard engine.current?.mappings.count == count else { return "mapped across kinds (palette, spectrum, value)" }

        // Unmapped, the palette is a grey ramp: with effects off the picture has no colour.
        let wasOn = scene.effects.map(\.enabled)
        for fx in scene.effects { fx.enabled = false }
        _ = engine.renderOffscreen(scene, frames: 3, snapshot: nil)
        let coloured = engine.averageColor(engine.renderer.history)
        engine.setStreamInput("generator.pal", nil)
        guard let bare = engine.current, bare.streamBindings["generator.pal"] == nil else { return "palette not unmapped" }
        for fx in bare.effects { fx.enabled = false }
        _ = engine.renderOffscreen(bare, frames: 3, snapshot: nil)
        let grey = engine.averageColor(engine.renderer.history)
        for (fx, on) in zip(bare.effects, wasOn) { fx.enabled = on }
        for (fx, on) in zip(scene.effects, wasOn) { fx.enabled = on }
        guard simd_length(coloured - grey) > 0.002, abs(grey.x - grey.y) < 0.002, abs(grey.y - grey.z) < 0.002 else {
            return "unmapped palette still coloured the scene: \(coloured) → \(grey)"
        }

        // Without Audio In, the spectrum mapping waits and the input is silent.
        engine.removeInput("audio")
        guard engine.current?.streamBindings["generator.spec"] == nil,
              engine.current?.mappings.first(where: { $0.target == "generator.spec" })?.problem == "Needs Audio In in the chain" else {
            return "spectrum still connected without Audio In"
        }

        // Nothing connects itself: a new generator's inputs start unmapped.
        engine.load(url, animated: false)
        engine.removeGenerator()
        engine.removeMappings(target: "generator.pal")
        engine.removeMappings(target: "generator.spec")
        engine.apply(.generator, "lowpoly")
        guard engine.current?.streamBindings.isEmpty == true else { return "new generator connected itself" }
        return nil
    }

    private static func checkStagesAndTransitions(engine: Engine) -> Bool {
        // 1. Verify stage loading and scene build
        guard let url = engine.sceneURLs.first(where: { $0.lastPathComponent == "01-ico-shatter.json" }),
              let sceneFile = try? SceneFile.load(url),
              let sceneA = engine.build(sceneFile, reuse: nil) else {
            return false
        }

        // 2. Verify 300ms crossfade controller
        let controller = TransitionController()
        guard let sceneB = engine.build(sceneFile, reuse: nil) else {
            return false
        }

        controller.start(from: sceneA, to: sceneB, now: 100.0)
        guard controller.isTransitioning else { return false }
        _ = controller.advance(now: 100.15)
        guard abs(controller.progress - 0.5) < 0.05 else { return false }
        _ = controller.advance(now: 100.35)
        guard !controller.isTransitioning && controller.progress >= 1.0 else { return false }

        return true
    }

    /// Edits a scene's chain in memory and checks the result. Nothing is saved.
    private static func checkComposition(engine: Engine) -> String? {
        guard let decoded = try? JSONDecoder().decode(SceneFile.self, from: Data(#"{"name":"x"}"#.utf8)),
              decoded.generator == nil, decoded.effects.isEmpty else { return "minimal scene JSON did not decode" }
        guard let url = engine.sceneURLs.first(where: { $0.lastPathComponent == "01-ico-shatter.json" }) else {
            return "01-ico-shatter.json missing"
        }
        let presetURL = engine.store.presetsDir(.generator, "lowpoly").appendingPathComponent("ico-shatter.json")
        let presetBefore = try? Data(contentsOf: presetURL)
        guard engine.tools.contains(where: { $0.name == "lowpoly" && $0.presets.contains { $0.id == "torus-swarm" } }) else {
            return "browser tools missing the lowpoly presets"
        }
        engine.load(url, animated: false)
        defer { engine.load(url, animated: false) }
        guard let start = engine.current else { return "scene did not load" }
        let n = start.effects.count

        engine.removeGenerator()
        guard engine.current?.generator == nil else { return "generator not removed" }
        engine.apply(.generator, "lowpoly")
        guard engine.current?.generator?.shape == .icosphere, engine.current?.generatorPreset == nil else { return "bare generator tool not loaded" }
        engine.apply(.generator, "lowpoly", preset: "torus-swarm")
        guard engine.current?.generatorPreset == "torus-swarm", engine.current?.generator?.shape == .torus,
              engine.current?.generator?.bank["instances"]?.base == 36 else { return "generator preset not loaded" }
        engine.apply(.effect, "glow", preset: "bloom", at: 0)
        guard let added = engine.current?.effects.first, added.effect == "glow", added.id != "glow",
              added.bank["amount"]?.base == 1.4, added.presetLabel == "Bloom",
              engine.current?.effects.count == n + 1 else { return "effect not inserted with a unique id" }
        engine.moveEffect(id: added.id, to: n + 1)
        guard engine.current?.effects.last?.id == added.id else { return "effect not moved to the end" }
        engine.moveEffect(id: added.id, to: 1)
        guard engine.current?.effects[1].id == added.id else { return "effect not moved to index 1" }
        engine.removeEffect(id: added.id)
        guard engine.current?.effects.count == n else { return "effect not removed" }
        engine.toggleCollapsed("generator")
        guard engine.isCollapsed("generator"), !engine.isCollapsed("camera") else { return "device not folded" }
        engine.toggleCollapsed("generator")
        guard !engine.isCollapsed("generator") else { return "device not unfolded" }
        engine.apply(.camera, "orbit", preset: "drift")
        guard engine.current?.cameraLabel == "Drift", engine.current?.camera["distance"]?.base == 9 else { return "camera preset not applied" }
        engine.apply(.palette, "palette", preset: "ice")
        guard engine.current?.paletteLabel == "Ice" else { return "palette preset not applied" }
        engine.removeInput("audio")
        guard engine.current?.hasAudioInput == false else { return "input not removed" }
        guard engine.isDirty else { return "edits not marked unsaved" }
        guard (try? Data(contentsOf: presetURL)) == presetBefore else { return "a scene edit wrote to a preset file" }
        return nil
    }

    /// A red test frame stands in for the camera: it should come out of the webcam's
    /// processing and show up behind the mesh when the generator's video bg is up.
    private static func checkWebcam(engine: Engine, snapshotDir: URL?) -> String? {
        guard let url = engine.sceneURLs.first(where: { $0.lastPathComponent == "01-ico-shatter.json" }) else { return "test scene missing" }
        engine.load(url, animated: false)
        defer { engine.load(url, animated: false) }
        engine.apply(.input, "webcam")
        guard engine.current?.mappings.contains(where: { $0.source.hasPrefix("webcam.") }) == false else {
            return "new webcam mapped itself"
        }
        engine.addMapping(source: "webcam.webcam.video", target: "generator.bgVideo")
        guard let added = engine.current, let first = added.webcams.first, first.key == "webcam.webcam",
              added.streamBindings["generator.bgVideo"] === first.video, engine.selectedDevice == "webcam.webcam",
              added.mappings.first(where: { $0.source == "webcam.webcam.video" })?.kind == .video else {
            return "webcam video not mapped into the generator's Background"
        }
        // Typed IO: video only into video inputs, values only into knobs.
        let count = added.mappings.count
        engine.addMapping(source: "webcam.webcam.video", target: "generator.spin")
        engine.addMapping(source: "audio.kick", target: "generator.texVideo")
        guard engine.current?.mappings.count == count else { return "mapped across kinds (video ↔ value)" }
        engine.addMapping(source: "webcam.webcam.video", target: "generator.texVideo")
        guard let scene = engine.current, let cam = scene.webcams.first,
              scene.streamBindings["generator.texVideo"] === cam.video,
              scene.streamInputs.map(\.label) == ["Palette", "Spectrum", "Background", "Texture", "Depth"] else { return "video not mapped into Texture" }
        guard cam.pipeline != nil, cam.bank["zoom"] != nil, cam.bank["mirror"]?.def.labels == ["Off", "Flip", "Fold", "Quad"] else {
            return "webcam shader not compiled or its knobs missing: \(engine.errors)"
        }
        guard scene.outputs.contains(where: { $0.key == "webcam.webcam.motion" }) else { return "webcam outputs missing" }

        // Solid red camera frame.
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 36, mipmapped: false)
        d.usage = .shaderRead
        guard let red = engine.device.makeTexture(descriptor: d) else { return "no test texture" }
        let px = [UInt8](repeating: 0, count: 64 * 36 * 4).enumerated().map { $0.offset % 4 == 2 || $0.offset % 4 == 3 ? 255 : 0 }
        red.replace(region: MTLRegionMake2D(0, 0, 64, 36), mipmapLevel: 0, withBytes: px.map(UInt8.init), bytesPerRow: 64 * 4)
        cam.feed.inject(red)

        guard let gen = scene.generator, let bg = gen.bank["videoBg"], let tex = gen.bank["videoTex"] else {
            return "generator has no video knobs"
        }
        bg.setBase(0); tex.setBase(0)
        _ = engine.renderOffscreen(scene, frames: 3, snapshot: nil)
        let processed = engine.averageColor(cam.processed)
        guard processed.x > 0.9, processed.y < 0.1, processed.z < 0.1 else { return "processed video not red: \(processed)" }
        let before = engine.averageColor(engine.renderer.history)
        bg.setBase(1)
        _ = engine.renderOffscreen(scene, frames: 3, snapshot: nil)
        let after = engine.averageColor(engine.renderer.history)
        guard after.x > before.x + 0.2 else { return "video bg didn't show the video: \(before) → \(after)" }

        // With a snapshot folder, show each way the generator can use video, from a test pattern.
        if let dir = snapshotDir {
            var pattern = [UInt8](repeating: 255, count: 64 * 36 * 4)
            for y in 0..<36 { for x in 0..<64 {
                let i = (y * 64 + x) * 4, check = ((x / 8) + (y / 8)) % 2 == 0
                pattern[i] = UInt8(x * 4); pattern[i + 1] = check ? 220 : 40; pattern[i + 2] = UInt8(255 - y * 7)
            } }
            red.replace(region: MTLRegionMake2D(0, 0, 64, 36), mipmapLevel: 0, withBytes: pattern, bytesPerRow: 64 * 4)
            let modes: [(String, Float, Float, Float)] = [("bg", 1, 0, 0), ("faces", 0, 1, 0), ("screen", 0.3, 1, 1),
                                                          ("shards", 0, 1, 2), ("sphere", 0, 1, 3), ("normal", 0, 1, 4)]
            // Effects off, so the snapshots show only what the generator does with the video.
            let wasOn = scene.effects.map(\.enabled)
            for fx in scene.effects { fx.enabled = false }
            for (name, b, t, mode) in modes {
                bg.setBase(b); tex.setBase(t); gen.bank["videoMap"]?.setBase(mode)
                _ = engine.renderOffscreen(scene, frames: 30, snapshot: dir.appendingPathComponent("webcam-\(name).png"))
            }
            for (fx, on) in zip(scene.effects, wasOn) { fx.enabled = on }
            red.replace(region: MTLRegionMake2D(0, 0, 64, 36), mipmapLevel: 0, withBytes: px.map(UInt8.init), bytesPerRow: 64 * 4)
        }

        guard !cam.depthMapped, !cam.feed.depthWanted, scene.streamOutputs.filter({ $0.kind == .video }).map(\.name) == ["Video", "Depth"] else {
            return "depth runs while unmapped, or the Depth output is missing"
        }
        engine.addMapping(source: "webcam.webcam.motion", target: "generator.spin")
        guard engine.current?.mappings.first(where: { $0.source == "webcam.webcam.motion" })?.isActive == true else {
            return "webcam output not mappable"
        }
        engine.removeInput("webcam.webcam")
        guard engine.current?.streamBindings.values.contains(where: { $0.kind == .video }) == false,
              engine.current?.mappings.first(where: { $0.target == "generator.bgVideo" })?.problem == "Needs its Webcam in the chain",
              engine.current?.mappings.first(where: { $0.source == "webcam.webcam.motion" })?.problem == "Needs its Webcam in the chain" else {
            return "removing the webcam left its video or mapping active"
        }
        return nil
    }

    /// The depth field scene, with a test depth standing in for the model (near on the left
    /// half, far on the right): it should come out of the depth pass framed like the video
    /// (mirrored, so near on the right), raise the field, and stop when unmapped.
    private static func checkDepth(engine: Engine, snapshotDir: URL?) -> String? {
        guard let url = engine.sceneURLs.first(where: { $0.lastPathComponent == "05-depth-field.json" }) else { return "depth scene missing" }
        engine.load(url, animated: false)
        guard let scene = engine.current, let cam = scene.webcams.first, let gen = scene.generator else { return "depth scene didn't build" }
        guard gen.shape == .field, scene.streamBindings["generator.depthVideo"] === cam.depthVideo,
              cam.depthMapped, cam.feed.depthWanted, cam.depthPipeline != nil else {
            return "depth not mapped into the field, or not running: \(engine.errors)"
        }
        let w = 48, h = 27
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let depth = engine.device.makeTexture(descriptor: d) else { return "no test texture" }
        let px = (0..<(w * h)).map { Float16($0 % w < w / 2 ? 1 : 0) }
        px.withUnsafeBytes { depth.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 2) }
        cam.feed.depth.inject(depth)

        let wasOn = scene.effects.map(\.enabled)
        for fx in scene.effects { fx.enabled = false }
        defer { for (fx, on) in zip(scene.effects, wasOn) { fx.enabled = on } }
        _ = engine.renderOffscreen(scene, frames: 60, snapshot: snapshotDir?.appendingPathComponent("depth-field.png"))
        let avg = engine.averageColor(cam.depth).x
        guard avg > 0.35, avg < 0.65 else { return "depth output should be half near, half far: \(avg)" }

        // Depth off: the field goes flat, so the picture changes.
        let with = engine.averageColor(engine.renderer.history)
        gen.bank["depth"]?.setBase(0)
        _ = engine.renderOffscreen(scene, frames: 3, snapshot: snapshotDir?.appendingPathComponent("depth-field-flat.png"))
        let without = engine.averageColor(engine.renderer.history)
        guard simd_length(with - without) > 0.005 else { return "depth didn't move the field: \(with) vs \(without)" }

        // With a snapshot folder, a person-shaped blob (head and shoulders) in front of a far
        // wall, under a test pattern video, the way a real camera would look.
        if let dir = snapshotDir {
            gen.bank["depth"]?.setBase(2.2)
            let figure = (0..<(w * h)).map { i -> Float16 in
                let x = Float(i % w) / Float(w) - 0.5, y = Float(i / w) / Float(h) - 0.5
                let head = 1 - simd_length(SIMD2(x * 1.8, (y + 0.12) * 1.1)) / 0.2
                let body = 1 - simd_length(SIMD2(x / 0.32, (y - 0.5) / 0.3))
                return Float16(max(0.15, min(1, max(head, body) * 4)))
            }
            figure.withUnsafeBytes { depth.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 2) }
            let vd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 36, mipmapped: false)
            vd.usage = .shaderRead
            if let video = engine.device.makeTexture(descriptor: vd) {
                var pattern = [UInt8](repeating: 255, count: 64 * 36 * 4)
                for y in 0..<36 { for x in 0..<64 {
                    let i = (y * 64 + x) * 4, check = ((x / 8) + (y / 8)) % 2 == 0
                    pattern[i] = UInt8(x * 4); pattern[i + 1] = check ? 220 : 40; pattern[i + 2] = UInt8(255 - y * 7)
                } }
                video.replace(region: MTLRegionMake2D(0, 0, 64, 36), mipmapLevel: 0, withBytes: pattern, bytesPerRow: 64 * 4)
                cam.feed.inject(video)
            }
            _ = engine.renderOffscreen(scene, frames: 60, snapshot: dir.appendingPathComponent("depth-figure.png"))
        }

        engine.setStreamInput("generator.depthVideo", nil)
        guard let after = engine.current?.webcams.first, !after.depthMapped, !after.feed.depthWanted else {
            return "depth still running after unmapping"
        }
        return nil
    }

    /// The real depth model on a synthetic camera frame, when it's installed: loads, runs, and
    /// hands back a grid with the camera's aspect. Returns (problem, summary).
    private static func checkDepthModel(engine: Engine) -> (String?, String) {
        guard DepthModel.packageURL != nil else { return (nil, "skipped, not installed (scripts/fetch-depth-model.sh)") }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let pb else { return ("no pixel buffer", "") }
        // A bright disc on a dark ground.
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<720 { for x in 0..<1280 {
            let dx = Float(x - 640) / 200, dy = Float(y - 360) / 200
            let v: UInt8 = dx * dx + dy * dy < 1 ? 230 : 30
            let p = base + y * row + x * 4
            p[0] = v; p[1] = v; p[2] = v; p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pb, [])
        let est = DepthEstimator(metal: engine.device)
        let start = Date()
        while est.latest() == nil, Date().timeIntervalSince(start) < 60 {
            est.submit(pb)
            if case .failed(let why) = est.status { return (why, "") }
            if est.status == .missingModel { return ("model not found", "") }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let tex = est.latest()?.texture else { return ("no depth after 60 s", "") }
        guard tex.width == DepthEstimator.gridWidth, tex.height == DepthEstimator.gridWidth * 9 / 16 else {
            return ("depth grid is \(tex.width)×\(tex.height)", "")
        }
        return (nil, String(format: "first depth after %.1f s, %.0f ms per frame", Date().timeIntervalSince(start), est.milliseconds))
    }

    private static func run(snapshotDir: URL?, audioPath: String?) -> Int32 {
        let engine = Engine(headless: true)
        if let audioPath {
            guard let audio = loadMono(audioPath) else { print("FAIL could not read \(audioPath)"); return 1 }
            engine.offlineAudio = audio
            print("audio: \(audioPath)")
        }
        var failures = 0
        print("content: \(engine.contentRoot.path)")

        for name in engine.availableEffects {
            if let err = engine.checkEffect(name) { print("FAIL effect \(name): \(err)"); failures += 1 }
            else { print("ok   effect \(name)") }
        }

        if let problem = checkMappings(engine: engine) {
            print("FAIL mappings: \(problem)"); failures += 1
        } else {
            print("ok   mappings (outputs, modulation, MIDI inputs, LFOs, paused devices, copy/paste, duplicate)")
        }

        if let problem = checkStreams(engine: engine) {
            print("FAIL streams: \(problem)"); failures += 1
        } else {
            print("ok   streams (palette and spectrum only through mappings, typed, nothing connects itself)")
        }

        let (modelProblem, modelSummary) = checkDepthModel(engine: engine)
        if let modelProblem { print("FAIL depth model: \(modelProblem)"); failures += 1 }
        else { print("ok   depth model (\(modelSummary))") }
        if let problem = checkDepth(engine: engine, snapshotDir: snapshotDir) {
            print("FAIL depth: \(problem)"); failures += 1
        } else {
            print("ok   depth (field mesh, depth pass, mapping, stops when unmapped)")
        }
        if let problem = checkWebcam(engine: engine, snapshotDir: snapshotDir) {
            print("FAIL webcam: \(problem)"); failures += 1
        } else {
            print("ok   webcam (processing, video into the generator, outputs, removal)")
        }

        if checkStagesAndTransitions(engine: engine) {
            print("ok   stage resolution & transitions")
        } else {
            print("FAIL stage resolution & transitions")
            failures += 1
        }

        if let problem = checkComposition(engine: engine) {
            print("FAIL composition: \(problem)"); failures += 1
        } else {
            print("ok   composition (tools, presets, add, move, remove; presets untouched)")
        }

        for url in engine.sceneURLs {
            engine.load(url, animated: false)
            let label = url.lastPathComponent
            guard engine.currentURL == url, let scene = engine.current else {
                print("FAIL scene \(label): \(engine.errorSummary ?? "did not load")"); failures += 1; continue
            }
            if let err = engine.errorSummary { print("FAIL scene \(label): \(err)"); failures += 1; continue }
            let ms = engine.renderOffscreen(scene, frames: 90, snapshot: snapshotDir?.appendingPathComponent(
                url.deletingPathExtension().lastPathComponent + ".png"))
            print(String(format: "ok   scene %@ (%d mappings, %.2f ms/frame GPU)", label, scene.mappings.count, ms))
        }
        print(failures == 0 ? "all checks passed" : "\(failures) failure(s)")
        return failures == 0 ? 0 : 1
    }
}

extension Engine {
    func checkEffect(_ name: String) -> String? {
        do {
            let shader = try ShaderCompiler(device: device, commonURL: store.commonShader).compile(store.effectShader(name))
            _ = try renderer.makeEffectPipeline(shader)
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// Mean RGB of a texture, read back through a shared copy.
    func averageColor(_ tex: MTLTexture) -> SIMD3<Float> {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: tex.pixelFormat, width: tex.width, height: tex.height, mipmapped: false)
        d.storageMode = .shared
        guard tex.pixelFormat == .rgba16Float, let copy = device.makeTexture(descriptor: d),
              let cmd = renderer.queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { return .zero }
        blit.copy(from: tex, to: copy)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        var px = [Float16](repeating: 0, count: tex.width * tex.height * 4)
        copy.getBytes(&px, bytesPerRow: tex.width * 8, from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0)
        var sum = SIMD3<Float>.zero
        for i in stride(from: 0, to: px.count, by: 4) { sum += SIMD3(Float(px[i]), Float(px[i + 1]), Float(px[i + 2])) }
        return sum / Float(tex.width * tex.height)
    }

    /// Renders frames at 60fps simulated time and returns the average GPU time per frame.
    func renderOffscreen(_ scene: RenderScene, frames: Int, snapshot: URL?) -> Double {
        var gpu = 0.0
        var signals = SignalFrame()
        let ring = SampleRing()
        let analyzer = AudioAnalyzer()
        var audioPos = 0
        for i in 0..<frames {
            signals.time = Float(i) / 60
            signals.dt = 1 / 60
            signals.beat = Double(i) / 60 * 2
            if let (samples, rate) = offlineAudio {
                ring.setSampleRate(rate)
                let n = Int(rate / 60)
                ring.write(frames: n) { k in samples[(audioPos + k) % samples.count] }
                audioPos += n
                analyzer.process(ring: ring, dt: 1 / 60, settings: audioSettings)
                renderer.updateSpectrum(analyzer.spectrum)
                let a = analyzer.features
                signals.bass = a.bass; signals.mid = a.mid; signals.high = a.high; signals.level = a.level
                signals.kick = a.kick; signals.snare = a.snare; signals.hat = a.hat
            }
            scene.modulate(signals)
            var f = FrameUniforms()
            f.time = signals.time; f.dt = signals.dt
            let cmd = renderer.queue.makeCommandBuffer()!
            renderer.encode(cmd, scene: scene, frame: &f)
            cmd.commit()
            cmd.waitUntilCompleted()
            if let e = cmd.error { print("  GPU error: \(e)") }
            gpu += cmd.gpuEndTime - cmd.gpuStartTime
        }
        if let snapshot { writePNG(renderer.history, to: snapshot) }
        return gpu / Double(frames) * 1000
    }

    private func writePNG(_ tex: MTLTexture, to url: URL) {
        let w = tex.width, h = tex.height
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Renderer.drawableFormat, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let out = device.makeTexture(descriptor: d), let cmd = renderer.queue.makeCommandBuffer() else { return }
        renderer.present(cmd, into: out)
        cmd.commit()
        cmd.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        out.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        for i in stride(from: 0, to: bytes.count, by: 4) { bytes.swapAt(i, i + 2) } // BGRA → RGBA
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: w * 4, bitsPerPixel: 32)!
        _ = bytes.withUnsafeBytes { memcpy(rep.bitmapData!, $0.baseAddress!, w * h * 4) }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
