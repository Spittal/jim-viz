import Foundation
import Metal
import AppKit
import AVFoundation

/// `JimViz --check [--snapshot dir]` compiles every shader, loads every scene, renders a few
/// frames of each offscreen, and exits non-zero on any error. Optionally writes PNG snapshots.
enum SelfCheck {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--analyze"), i + 1 < args.count {
            let truth = args.firstIndex(of: "--truth").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            exit(analyzeFile(args[i + 1], truthPath: truth))
        }
        if let i = args.firstIndex(of: "--capture-test") {
            let src = i + 1 < args.count ? args[i + 1] : "system"
            if src.hasPrefix("pid:"), let pid = pid_t(src.dropFirst(4)) {
                captureTest(source: .rekordbox, pid: pid)
            }
            guard let source = AudioCapture.Source(key: src) else { print("unknown source \(src): rekordbox, system or input:<uid>"); exit(1) }
            captureTest(source: source, pid: nil)
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
        let capture = AudioCapture(source: source, channelPair: 0)
        if let pid { capture.processFilter = { $0.processPID == pid } }
        let analyzer = AudioAnalyzer()
        capture.setActive(true)
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
        guard let url = engine.sceneURLs.first(where: { $0.lastPathComponent == "kaleido.json" }) else {
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
        guard let intensity = scene.outputs.first(where: { $0.key == "audio.intensity" }),
              let audioIn = scene.audioIn else { return "no intensity output" }
        var loud = AudioFeatures()
        loud.level = 1; loud.bass = 1; loud.kick = 1; loud.snare = 0.5
        audioIn.features = loud
        for _ in 0..<180 { intensity.update(SignalFrame()) }
        guard intensity.value > 0.7 else { return "intensity didn't rise: \(intensity.value)" }

        // Audio In's and the Clock's knobs belong to the scene and map like any other.
        engine.addMapping(source: "mod.lfo.out", target: "audio.gate")
        engine.addMapping(source: "audio.kick", target: "clock.latency")
        guard let tools = engine.current, tools.mappings.filter({ $0.target == "audio.gate" || $0.target == "clock.latency" }).allSatisfy(\.isActive),
              tools.audioIn?.bank["gate"]?.isModulated == true, tools.clock?.bank["latency"]?.isModulated == true else {
            return "Audio In or Clock knobs not mappable"
        }
        tools.audioIn?.bank["sensitivity"]?.setBase(0.8)
        tools.clock?.bank["minBPM"]?.setBase(100)
        guard let saved = engine.currentSnapshot(),
              saved.inputs.first(where: { $0.type == "audio" })?.params?["sensitivity"] == 0.8,
              saved.inputs.first(where: { $0.type == "clock" })?.params?["minBPM"] == 100 else {
            return "Audio In or Clock knobs not saved with the scene"
        }
        engine.removeMappings(target: "audio.gate")
        engine.removeMappings(target: "clock.latency")

        // Palette inputs: hue turns red to green at +120°, brightness scales, and they're mappable.
        let green = PaletteParams.adjust(SIMD3(1, 0, 0)) { ["hue": 120, "saturation": 1, "brightness": 1][$0] ?? 1 }
        guard green.y > 0.9, green.x < 0.1, green.z < 0.1 else { return "palette hue wrong: \(green)" }
        engine.addMapping(source: "audio.kick", target: "palette.brightness")
        guard engine.current?.mappings.first(where: { $0.target == "palette.brightness" })?.isActive == true,
              engine.current?.palette?.bank["brightness"]?.isModulated == true else { return "palette input not mappable" }
        engine.current?.palette?.bank["hue"]?.setBase(30)
        engine.apply(.palette, "palette", preset: "ice")
        guard engine.current?.palette?.bank["hue"]?.base == 30 else { return "palette inputs lost on a preset change" }

        // Frames that take no time, at a beat set on the scene's own Clock.
        var f = SignalFrame()
        f.dt = 0
        engine.current?.clock?.manager.seek(beat: 8)  // on a downbeat: pulse = 1, bar ramp = 0

        // Modulation adds amount × signal × range on top of the knob.
        engine.addMapping(source: "clock.pulse", target: "camera.fov")
        guard let s1 = engine.current, let fov = s1.camera?["fov"],
              let m = s1.mappings.first(where: { $0.source == "clock.pulse" && $0.target == "camera.fov" }),
              m.isActive, m.amount == 0.25, fov.isModulated else { return "pulse → fov not mapped" }
        s1.modulate(f)
        guard abs(fov.live - fov.def.clamp(fov.base + 0.25 * fov.def.span)) < 0.01 else { return "modulation amount wrong: \(fov.live)" }
        // Invert pushes the knob down by the amount instead.
        m.amount = 0.1
        m.invert = true
        s1.modulate(f)
        guard abs(fov.live - fov.def.clamp(fov.base - 0.1 * fov.def.span)) < 0.01 else { return "inverted amount wrong" }
        guard abs(m.contribution + 0.1) < 0.001 else { return "mapping contribution wrong: \(m.contribution)" }
        // Settings survive structural edits.
        engine.addMapping(source: "clock.bar", target: "camera.roll")
        guard let kept = engine.current?.mappings.first(where: { $0.target == "camera.fov" }),
              kept.amount == 0.1, kept.invert else {
            return "mapping settings lost on rebuild"
        }
        // Amounts are 0...1: a negative one is invalid, not quietly inverted.
        if var bad = engine.currentSnapshot(), var list = bad.mappings, let i = list.firstIndex(where: { $0.target == "camera.fov" }) {
            list[i].amount = -0.1
            bad.mappings = list
            guard engine.build(bad, reuse: nil) == nil, engine.errors["mapping"] != nil else { return "negative amount built" }
        } else {
            return "no scene snapshot"
        }

        // MIDI Input: while learning, controls moved on its device become outputs,
        // which then map like any other output.
        func cc(_ number: Int, _ value: Int, channel: Int = 7, device: String = "DDJ-FLX4") -> MIDIMessage {
            MIDIMessage(channel: channel, command: .controlChange, data1: number, data2: value, timestamp: 0, device: device)
        }
        engine.apply(.input, "midi", preset: "DDJ-FLX4")
        guard engine.current?.learningMIDI?.key == "midi.midi", engine.selectedDevice == "midi.midi" else { return "new MIDI input not learning" }
        engine.handleMIDI(cc(31, 127, device: "Other Controller"))
        guard engine.current?.midiInputs.first?.controls.isEmpty == true else { return "learned a control from another device" }
        engine.handleMIDI(cc(31, 127))
        engine.handleMIDI(cc(31, 120))
        guard engine.current?.midiInputs.first?.controls.count == 1,
              let fader = engine.current?.outputs.first(where: { $0.key == "midi.midi.cc-31-7" }),
              fader.name == "Crossfader" else { return "MIDI control not learned once as an output" }
        guard engine.current?.learningMIDI?.key == "midi.midi" else { return "MIDI input stopped learning after a control" }
        engine.current?.learnMIDI(nil)
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

        // LFOs: unique ids, starts free, syncs only with Clock mapping, bipolar output, mappable knobs.
        engine.apply(.modulation, "lfo", preset: "bar-saw")
        guard let lfo2 = engine.current?.modulators.first(where: { $0.id == "lfo2" }), lfo2.id == "lfo2", lfo2.presetLabel == "Bar Saw" else {
            return "LFO preset not added as lfo2"
        }
        guard engine.current?.modulators.map(\.id) == ["lfo", "lfo2"],
              engine.current?.effects.contains(where: { $0.id == "lfo2" }) == false else {
            return "LFO not added to the Modulation section"
        }
        guard lfo2.isSynced == false else { return "LFO starts synced without a mapping" }
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
        // Sync via mapping only: typed stream mapping.
        let mapCount = engine.current?.mappings.count ?? 0
        engine.addMapping(source: "audio.kick", target: "mod.lfo2.sync")
        guard engine.current?.mappings.count == mapCount else { return "value mapped into clock sync input" }
        engine.addMapping(source: StreamOutput.clockSyncKey, target: "mod.lfo2.sync")
        guard let s2 = engine.current, s2.modulators.first(where: { $0.id == "lfo2" })?.isSynced == true else {
            return "LFO not synced after clock mapping"
        }
        guard s2.mappings.filter({ $0.source.hasPrefix("mod.") }).allSatisfy(\.isActive) else {
            return "LFO mappings inactive"
        }
        let depth = s2.modulators.first { $0.id == "lfo2" }!.bank["depth"]!.live
        // Synced 1-bar saw up: at beat 3 (3/4 cycle), bipolar output is +0.5 * depth.
        s2.clock?.manager.seek(beat: 3)
        s2.modulate(f)
        s2.modulate(f)
        guard let out = s2.outputs.first(where: { $0.key == "mod.lfo2.out" }),
              abs(out.value - 0.5 * depth) < 0.02 else { return "LFO positive output wrong" }
        // At beat 1 (1/4 cycle), bipolar output is -0.5 * depth (negative swing).
        s2.clock?.manager.seek(beat: 1)
        s2.modulate(f)
        s2.modulate(f)
        guard abs(out.value - (-0.5 * depth)) < 0.02 else { return "LFO negative bipolar output wrong" }
        // Removing clock mapping reverts LFO to free running.
        engine.removeMappings(target: "mod.lfo2.sync")
        guard engine.current?.modulators.first(where: { $0.id == "lfo2" })?.isSynced == false else {
            return "LFO still synced after sync mapping removed"
        }
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

    /// Every camera rig: its presets name only its own knobs, it moves sensibly from its
    /// defaults, Static stays put, Orbit's snap lands on whole steps, Cutter cuts on a rising
    /// trigger, and a scene with an unknown camera type fails to load.
    private static func checkCameras(engine: Engine) -> String? {
        var f = FrameUniforms()
        f.resolution = SIMD2(1920, 1080)
        f.dt = 1 / 60
        func bank(_ rig: CameraRig, _ values: [String: Float] = [:]) -> ParamBank {
            ParamBank(defs: rig.defs, values: values)
        }
        for rig in CameraRig.allCases {
            let names = Set(rig.defs.map(\.name))
            guard names.count == rig.defs.count else { return "\(rig.rawValue) has duplicate knobs" }
            for id in engine.store.presetIDs(.camera, rig.rawValue) {
                guard let preset = engine.store.preset(.camera, rig.rawValue, id) else { return "camera preset \(rig.rawValue)/\(id): JSON invalid" }
                let unknown = Set(preset.params?.keys.map { $0 } ?? []).subtracting(names)
                guard unknown.isEmpty else { return "camera preset \(rig.rawValue)/\(id) has unknown knobs \(unknown.sorted())" }
            }
            let motion = CameraMotion(rig), b = bank(rig)
            for _ in 0..<240 {
                let pose = motion.advance(b, frame: f)
                guard simd_reduce_add(pose.eye + pose.target).isFinite, simd_distance(pose.eye, pose.target) > 0.01,
                      pose.fov >= 5, pose.fov <= 160, pose.roll.isFinite else {
                    return "\(rig.rawValue) camera pose invalid: \(pose)"
                }
            }
            for o in motion.outputs { o.update(SignalFrame()) }
        }

        let still = CameraMotion(.still), stillBank = bank(.still)
        let first = still.advance(stillBank, frame: f)
        for _ in 0..<60 { _ = still.advance(stillBank, frame: f) }
        guard still.advance(stillBank, frame: f).eye == first.eye else { return "static camera moved" }

        let orbit = CameraMotion(.orbit), orbitBank = bank(.orbit, ["snap": 4, "sway": 0, "orbitSpeed": 0.7, "distance": 5, "height": 0])
        for _ in 0..<100 {
            let e = orbit.advance(orbitBank, frame: f).eye
            guard min(abs(e.x), abs(e.z)) < 0.001, abs(max(abs(e.x), abs(e.z)) - 5) < 0.001 else { return "orbit snap off the steps: \(e)" }
        }

        let cutter = CameraMotion(.cutter), cutterBank = bank(.cutter, ["rate": 0, "shake": 0, "drift": 0])
        guard let cutOut = cutter.outputs.first(where: { $0.key == "camera.cut" }) else { return "cutter has no cut output" }
        let before = cutter.advance(cutterBank, frame: f).eye
        cutterBank["trigger"]?.live = 1
        let afterCut = cutter.advance(cutterBank, frame: f).eye
        cutOut.update(SignalFrame())
        guard afterCut != before, cutOut.value == 1 else { return "cutter didn't cut on the trigger" }
        let held = cutter.advance(cutterBank, frame: f).eye
        guard held == afterCut else { return "cutter cut again while the trigger stayed high" }
        cutterBank["trigger"]?.live = 0
        _ = cutter.advance(cutterBank, frame: f)
        cutterBank["trigger"]?.live = 1
        guard cutter.advance(cutterBank, frame: f).eye != held else { return "cutter didn't re-arm" }

        // Scenes: a new camera type loads with its outputs, an unknown one is an error.
        let url = engine.store.scenesDir.appendingPathComponent("selfcheck-camera.json")
        defer {
            try? FileManager.default.removeItem(at: url)
            engine.refreshSceneList()
            if let kaleido = engine.sceneURLs.first(where: { $0.lastPathComponent == "kaleido.json" }) { engine.load(kaleido, animated: false) }
        }
        func write(_ type: String) -> Bool {
            let file = SceneFile(name: "Self-check Camera", inputs: [], modulators: [], camera: CameraSlot(type: type),
                                 palette: PaletteSlot(colors: Tools.defaultPalette), generator: nil, effects: [], mappings: [])
            guard (try? file.write(to: url)) != nil else { return false }
            engine.store.markSeen(url)
            engine.refreshSceneList()
            return true
        }
        guard write("cutter") else { return "could not write the test scene" }
        engine.load(url, animated: false)
        guard engine.current?.cameraMotion?.rig == .cutter, engine.current?.outputs.contains(where: { $0.key == "camera.cut" }) == true,
              engine.current?.mappings.isEmpty == true else { return "cutter scene didn't load with its output and no mappings" }
        guard write("dolly") else { return "could not write the test scene" }
        engine.load(url, animated: false)
        guard engine.errors["camera"] != nil else { return "unknown camera type loaded without an error" }
        return nil
    }

    /// Nothing reaches a shader except through a mapping: the palette and spectrum are typed
    /// outputs, and unmapped means grey and still.
    private static func checkStreams(engine: Engine) -> String? {
        guard let url = engine.sceneURLs.first(where: { $0.lastPathComponent == "kaleido.json" }) else { return "test scene missing" }
        engine.load(url, animated: false)
        defer { engine.load(url, animated: false) }
        guard let scene = engine.current, scene.generator != nil else { return "scene did not load" }
        guard scene.streamBindings["generator.pal"]?.key == "palette.colors",
              scene.streamBindings["generator.spec"]?.key == "audio.spectrum",
              scene.streamOutputs.map(\.key) == ["audio.spectrum", "audio.out", "clock.sync", "palette.colors"] else {
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
        engine.apply(.generator, "torus")
        guard engine.current?.streamBindings.filter({ $0.key.hasPrefix("generator.") }).isEmpty == true else { return "new generator connected itself" }
        return nil
    }

    /// The crossfade's timing, and that it really blends the outgoing scene into the incoming
    /// one: at the start the picture is the outgoing scene, at the end the incoming one.
    private static func checkTransitions(engine: Engine) -> String? {
        guard let urlA = engine.sceneURLs.first(where: { $0.lastPathComponent == "kaleido.json" }),
              let urlB = engine.sceneURLs.first(where: { $0.lastPathComponent == "sammy-style.json" }),
              let fileA = try? SceneFile.load(urlA), let fileB = try? SceneFile.load(urlB),
              let sceneA = engine.build(fileA, reuse: nil), let sceneB = engine.build(fileB, reuse: nil) else {
            return "test scenes missing"
        }

        let controller = TransitionController()
        controller.start(from: sceneA, to: sceneB, now: 100.0)
        guard controller.isTransitioning else { return "crossfade did not start" }
        _ = controller.advance(now: 100.15)
        guard abs(controller.progress - 0.5) < 0.05 else { return "crossfade not halfway at 150 ms" }
        _ = controller.advance(now: 100.35)
        guard !controller.isTransitioning && controller.progress >= 1.0 else { return "crossfade did not finish by 350 ms" }

        // Each scene alone, then the crossfade at its start and end, all without audio so the
        // pictures compare like for like.
        let audio = engine.offlineAudio
        engine.offlineAudio = nil
        defer { engine.offlineAudio = audio }
        _ = engine.renderOffscreen(sceneA, frames: 5, snapshot: nil)
        let a = engine.averageColor(engine.renderer.history)
        _ = engine.renderOffscreen(sceneB, frames: 5, snapshot: nil)
        let b = engine.averageColor(engine.renderer.history)
        guard simd_length(a - b) > 0.01 else { return "test scenes look the same: \(a) vs \(b)" }
        // Each scene's camera should move at its own speed, once per frame, while both are drawn.
        let orbitA = sceneA.cameraMotion?.orbit ?? 0, orbitB = sceneB.cameraMotion?.orbit ?? 0
        var expectA: Float = 0, expectB: Float = 0
        var start = SIMD3<Float>.zero
        for i in 0..<10 {
            if i == 5 { start = engine.averageColor(engine.renderer.history) }
            engine.renderTransition(from: sceneA, to: sceneB, progress: i < 5 ? 0 : 1, frames: 1)
            expectA += (sceneA.camera?.live("orbitSpeed") ?? 0) / 60
            expectB += (sceneB.camera?.live("orbitSpeed") ?? 0) / 60
        }
        let end = engine.averageColor(engine.renderer.history)
        guard simd_length(start - a) < simd_length(start - b) else {
            return "crossfade start doesn't show the outgoing scene: \(start), outgoing \(a), incoming \(b)"
        }
        guard simd_length(end - b) < simd_length(end - a) else {
            return "crossfade end doesn't show the incoming scene: \(end), outgoing \(a), incoming \(b)"
        }

        let movedA = (sceneA.cameraMotion?.orbit ?? 0) - orbitA, movedB = (sceneB.cameraMotion?.orbit ?? 0) - orbitB
        guard abs(movedA - expectA) < 1e-3, abs(movedB - expectB) < 1e-3 else {
            return "cameras moved \(movedA), \(movedB) in 10 crossfade frames; expected \(expectA), \(expectB)"
        }
        return nil
    }

    /// The Clock follows audio only through a mapping: Audio In · Audio Out into Clock · Audio.
    private static func checkClockAudio(engine: Engine) -> String? {
        guard let url = engine.sceneURLs.first(where: { $0.lastPathComponent == "kaleido.json" }) else { return "test scene missing" }
        engine.load(url, animated: false)
        defer { engine.load(url, animated: false) }
        guard let scene = engine.current, scene.hasClock, scene.hasAudioInput else { return "test scene needs Audio In and Clock" }
        engine.removeMappings(target: StreamInput.clockAudioKey)
        guard engine.current?.clockHearsAudio == false else { return "Clock hears audio without a mapping" }

        // Typed: audio only into the Clock, and the Clock takes only audio.
        let count = engine.current?.mappings.count
        engine.addMapping(source: StreamOutput.audioKey, target: "generator.spec")
        engine.addMapping(source: StreamOutput.audioKey, target: "camera.fov")
        engine.addMapping(source: StreamOutput.spectrumKey, target: StreamInput.clockAudioKey)
        engine.addMapping(source: "audio.kick", target: StreamInput.clockAudioKey)
        guard engine.current?.mappings.count == count else { return "audio mapped across kinds" }

        engine.addMapping(source: StreamOutput.audioKey, target: StreamInput.clockAudioKey)
        guard engine.current?.clockHearsAudio == true else { return "Audio Out → Clock · Audio did not connect" }

        // Without Audio In the mapping waits; without the Clock it has nowhere to go.
        engine.removeInput("audio")
        guard engine.current?.clockHearsAudio == false,
              engine.current?.mappings.first(where: { $0.target == StreamInput.clockAudioKey })?.problem == "Needs Audio In in the chain" else {
            return "Clock still hears audio without Audio In"
        }
        engine.apply(.input, "audio")
        guard engine.current?.clockHearsAudio == true else { return "mapping did not resume when Audio In came back" }

        // Nothing connects itself: a Clock added to a scene starts unmapped.
        engine.removeMappings(target: StreamInput.clockAudioKey)
        engine.removeInput("clock")
        engine.apply(.input, "clock")
        guard engine.current?.hasClock == true, engine.current?.clockHearsAudio == false else { return "new Clock connected itself" }

        // The clock follows a steady beat only while it hears it.
        func run(hearing: Bool) -> ClockSourceKind {
            let clock = ClockManager()
            let period = 60.0 / 124
            for i in 0..<(60 * 10) {
                let t = Double(i) / 60
                let onBeat = (t.truncatingRemainder(dividingBy: period)) < 1.0 / 60
                if hearing { clock.audioTempo.feed(strength: onBeat ? 1 : 0, active: true, time: t) }
                clock.advance(now: t, dt: 1.0 / 60, hearsAudio: hearing)
            }
            return clock.active
        }
        guard run(hearing: false) == .manual else { return "clock followed audio it wasn't mapped to hear" }
        guard run(hearing: true) == .audio else { return "clock didn't follow a steady mapped beat" }

        // First Beat: the beat nearest the press becomes bar 1, beat 1 of the phrase, whether
        // pressed a little early or late, without the output jumping.
        func firstBeat(early: Bool, hearing: Bool) -> String? {
            let clock = ClockManager()
            let period = 60.0 / 124
            let dt = 1.0 / 60
            let downbeat = period * 20  // the beat the user means, ~10 s in
            let press = downbeat + (early ? -0.1 : 0.1) * period
            var pressed = false
            var last: Double?
            for i in 0..<(60 * 16) {
                let t = Double(i) * dt
                let onBeat = (t.truncatingRemainder(dividingBy: period)) < dt
                if hearing { clock.audioTempo.feed(strength: onBeat ? 1 : 0, active: true, time: t) }
                if !pressed, t >= press { clock.firstBeat(at: press); pressed = true }
                clock.advance(now: t, dt: dt, hearsAudio: hearing)
                if let l = last {
                    // Renumbering moves the count by whole beats only; the phase keeps flowing.
                    let step = clock.beat - l
                    let phaseStep = step - step.rounded()
                    if abs(phaseStep) > 2 * dt * 124 / 60 { return "First Beat made the clock jump (hearing: \(hearing))" }
                }
                last = clock.beat
            }
            if hearing, clock.active != .audio { return "clock lost the beat after First Beat" }
            // At the end, the beat count should match the beats elapsed since the downbeat:
            // following audio that's the beat the press was nearest; on the manual clock, the
            // press itself.
            let end = Double(60 * 16 - 1) * dt
            let expected = (end - (hearing ? downbeat : press)) / period
            let off = clock.beat - expected
            guard abs(off) < 0.05 else {
                return String(format: "First Beat pressed %@ landed %.2f beats off (hearing: %@)",
                              early ? "early" : "late", off, hearing ? "yes" : "no")
            }
            return nil
        }
        for hearing in [true, false] {
            for early in [true, false] {
                if let e = firstBeat(early: early, hearing: hearing) { return e }
            }
        }
        return nil
    }

    /// Every scene owns its tools: Audio In analyses with its own knobs and Clock keeps its own
    /// beat, nothing is broadcast to scenes without them, a switch continues levels and the
    /// beat, and hardware stays off without a device that uses it.
    private static func checkEncapsulation(engine: Engine) -> String? {
        guard let urlA = engine.sceneURLs.first(where: { $0.lastPathComponent == "kaleido.json" }),
              let urlB = engine.sceneURLs.first(where: { $0.lastPathComponent == "sammy-style.json" }),
              let fileB = try? SceneFile.load(urlB) else { return "test scenes missing" }
        engine.load(urlA, animated: false)
        defer { engine.load(urlA, animated: false) }
        guard let a = engine.current, let audioA = a.audioIn, let clockA = a.clock else { return "test scene needs Audio In and Clock" }

        // Switching: the incoming scene has its own Audio In and Clock, which pick up the
        // outgoing scene's beat on their first frame.
        var still = SignalFrame()
        still.dt = 0
        clockA.manager.seek(beat: 17.5)
        guard let b = engine.build(fileB, reuse: nil), let audioB = b.audioIn, let clockB = b.clock else { return "second scene needs Audio In and Clock" }
        guard audioA !== audioB, audioA.analyzer !== audioB.analyzer, audioA.bank !== audioB.bank,
              audioA.spectrum !== audioB.spectrum, clockA.manager !== clockB.manager else { return "scenes share Audio In or Clock state" }
        b.modulate(still)
        guard abs(clockB.beat - 17.5) < 1e-6 else { return "incoming Clock didn't continue the beat: \(clockB.beat)" }
        clockB.manager.seek(beat: 2)
        a.modulate(still)
        guard abs(clockA.beat - 17.5) < 1e-6 else { return "one scene's Clock moved another's" }

        // Audio In's source is the scene's: scenes on the same source share one capture, another
        // source or channel pair gets its own, and a scene must name its source.
        guard audioA.capture === audioB.capture, audioA.capture.source == .systemAudio else { return "scenes on one source don't share its capture" }
        engine.setAudioSource(.rekordbox)
        guard let rb = engine.current?.audioIn, rb.capture.source == .rekordbox, rb.capture !== audioA.capture,
              rb.analyzer !== audioA.analyzer,
              engine.currentSnapshot()?.inputs.first(where: { $0.type == "audio" })?.device == "rekordbox" else {
            return "Audio In source not switched and saved with the scene"
        }
        engine.setAudioChannelPair(1)
        guard let pair = engine.current?.audioIn?.capture, pair.channelPair == 1, pair !== rb.capture,
              engine.currentSnapshot()?.inputs.first(where: { $0.type == "audio" })?.channelPair == 1 else {
            return "Audio In channel pair not switched and saved with the scene"
        }
        engine.setAudioSource(.systemAudio)
        guard engine.current?.audioIn?.capture === audioA.capture else { return "switching back didn't reuse the source's capture" }
        for device in [nil, "bogus"] as [String?] {
            let file = SceneFile(name: "x", inputs: [InputSpec(type: "audio", device: device)], modulators: [],
                                 camera: nil, palette: nil, generator: nil, effects: [], mappings: [])
            guard engine.build(file, reuse: nil) == nil, engine.errors["input"]?.hasPrefix("Audio In needs a device") == true else {
                return "Audio In built without a valid source (\(device ?? "none"))"
            }
        }
        engine.load(urlA, animated: false)
        guard let a2 = engine.current, let audioA2 = a2.audioIn, let clockA2 = a2.clock else { return "test scene did not reload" }

        // A chain edit keeps the same analysis and beat running.
        engine.apply(.effect, "glow")
        guard let edited = engine.current, edited.audioIn?.analyzer === audioA2.analyzer, edited.clock?.manager === clockA2.manager else {
            return "a chain edit restarted Audio In or Clock"
        }

        // Without Audio In or Clock there are no audio or clock outputs, and LFOs run free.
        engine.addMapping(source: StreamOutput.clockSyncKey, target: "mod.lfo.sync")
        guard engine.current?.modulators.first?.isSynced == true else { return "LFO did not sync" }
        engine.removeInput("audio")
        engine.removeInput("clock")
        guard let bare = engine.current, bare.audioIn == nil, bare.clock == nil,
              !bare.outputs.contains(where: { $0.key.hasPrefix("audio.") || $0.key.hasPrefix("clock.") }),
              !bare.streamOutputs.contains(where: { $0.key.hasPrefix("audio.") || $0.key.hasPrefix("clock.") }),
              bare.modulators.allSatisfy({ !$0.isSynced }) else { return "audio or clock signals reach a scene without them" }

        // Headless, no hardware runs.
        guard engine.audioCaptures.all.allSatisfy({ !$0.isActive }), !engine.midi.isActive else { return "hardware started without a device on screen" }
        return nil
    }

    /// Every Low Poly geo: listed under its category, its own knobs, starts unmapped, renders, and
    /// rebuilds its mesh when a mesh knob changes, by hand or by modulation.
    private static func checkLowPoly(engine: Engine) -> String? {
        let geos = ["sphere", "torus", "plane", "cube", "shards", "wheel"]
        let listed = engine.tools.filter { $0.kind == .generator && $0.category == "lowpoly" }.map(\.name)
        guard Set(listed) == Set(geos) else { return "Low Poly lists \(listed), expected \(geos)" }
        guard !engine.tools.contains(where: { $0.name.hasPrefix("_") }) else { return "shared shader code listed as a tool" }
        guard let url = engine.sceneURLs.first(where: { $0.lastPathComponent == "kaleido.json" }) else { return "kaleido.json missing" }
        engine.load(url, animated: false)
        defer { engine.load(url, animated: false) }
        for target in Set(engine.current?.mappings.map(\.target) ?? []) where target.hasPrefix("generator") {
            engine.removeMappings(target: target)
        }
        // Knobs that belong to one geo only.
        let own: [String: String] = ["sphere": "squash", "torus": "thickness", "plane": "jitter",
                                     "cube": "inflate", "shards": "shardSpin", "wheel": "pitch"]
        for geo in geos {
            while let gen = engine.current?.generators.first { engine.removeGenerator(key: gen.key) }
            engine.apply(.generator, geo)
            guard let gen = engine.current?.generator, gen.type == geo, gen.mesh.rawValue == geo else {
                return "\(geo) didn't load: \(engine.errorSummary ?? "")"
            }
            guard gen.vertexCount > 0 else { return "\(geo) built an empty mesh" }
            for (other, knob) in own { if (gen.bank[knob] != nil) != (other == geo) { return "\(geo) has the wrong knobs (\(knob))" } }
            guard (gen.bank["depth"] != nil) == (geo == "plane") else { return "depth should be on the plane only" }
            guard engine.current?.streamBindings.keys.contains(where: { $0.hasPrefix(gen.key + ".") }) == false else {
                return "\(geo) connected itself"
            }
            let meshKnobs = gen.bank.params.filter(\.def.rebuildsMesh)
            guard meshKnobs.map(\.def.name).sorted() == gen.mesh.meshParams.sorted() else { return "\(geo) mesh knobs mismatch" }
            // A modulated mesh knob (live above its base) rebuilds in the background.
            let knob = meshKnobs[0], before = gen.vertexCount
            knob.live = knob.def.clamp(knob.base + knob.def.span * 0.25)
            gen.finishMeshBuild(device: engine.device)
            guard gen.vertexCount != before else { return "\(geo) mesh didn't rebuild when \(knob.def.name) changed" }
            knob.live = knob.base
            gen.finishMeshBuild(device: engine.device)
            guard gen.vertexCount == before else { return "\(geo) mesh didn't return when \(knob.def.name) went back" }

            // Dimension and scale params can go to 0 without errors ("zero would be it's not there").
            if let scale = gen.bank["scale"] {
                guard scale.def.min == 0 else { return "\(geo) scale min is \(scale.def.min), expected 0" }
                scale.setBase(0)
                _ = engine.renderOffscreen(engine.current!, frames: 1, snapshot: nil)
                scale.reset()
            }

            // Motion group defaults to 0 spin and tumble, and resets cleanly.
            guard let spin = gen.bank["spin"], let tumble = gen.bank["tumble"] else {
                return "\(geo) missing spin or tumble"
            }
            guard spin.def.defaultValue == 0, tumble.def.defaultValue == 0 else {
                return "\(geo) motion default should be 0s, got spin \(spin.def.defaultValue), tumble \(tumble.def.defaultValue)"
            }
            spin.setBase(2.0); spin.phase = 1.5
            tumble.setBase(1.5); tumble.phase = 2.0
            spin.reset(); spin.phase = 0
            tumble.reset(); tumble.phase = 0
            guard spin.base == 0, spin.phase == 0, tumble.base == 0, tumble.phase == 0 else {
                return "\(geo) motion reset did not return to 0s"
            }
            if geo == "wheel" {
                guard let w = gen.bank["width"], w.def.min == 0,
                      let l = gen.bank["length"], l.def.min == 0 else { return "wheel width/length min should be 0" }
                w.setBase(0); l.setBase(0)
                _ = engine.renderOffscreen(engine.current!, frames: 1, snapshot: nil)
                w.reset(); l.reset()
            }
            if geo == "torus" {
                guard let t = gen.bank["thickness"], t.def.min == 0 else { return "torus thickness min should be 0" }
                t.setBase(0)
                _ = engine.renderOffscreen(engine.current!, frames: 1, snapshot: nil)
                t.reset()
            }
            if geo == "sphere" {
                guard let sq = gen.bank["squash"], sq.def.min == 0 else { return "sphere squash min should be 0" }
                sq.setBase(0)
                _ = engine.renderOffscreen(engine.current!, frames: 1, snapshot: nil)
                sq.reset()
            }
            if geo == "plane" {
                guard let w = gen.bank["width"], w.def.min == 0,
                      let h = gen.bank["height"], h.def.min == 0 else { return "plane width/height min should be 0" }
                w.setBase(0); h.setBase(0)
                _ = engine.renderOffscreen(engine.current!, frames: 1, snapshot: nil)
                w.reset(); h.reset()
            }

            _ = engine.renderOffscreen(engine.current!, frames: 2, snapshot: nil)
            if let err = engine.errorSummary { return "\(geo): \(err)" }
        }
        return nil
    }

    /// Edits a scene's chain in memory and checks the result. Nothing is saved.
    private static func checkComposition(engine: Engine) -> String? {
        guard let decoded = try? JSONDecoder().decode(SceneFile.self, from: Data(#"{"name":"x"}"#.utf8)),
              decoded.generator == nil, decoded.effects.isEmpty else { return "minimal scene JSON did not decode" }
        guard let url = engine.sceneURLs.first(where: { $0.lastPathComponent == "kaleido.json" }) else {
            return "kaleido.json missing"
        }
        let presetURL = engine.store.presetsDir(.effect, "glow").appendingPathComponent("bloom.json")
        let presetBefore = try? Data(contentsOf: presetURL)
        engine.load(url, animated: false)
        defer { engine.load(url, animated: false) }
        guard let start = engine.current else { return "scene did not load" }
        let n = start.effects.count

        while let gen = engine.current?.generators.first { engine.removeGenerator(key: gen.key) }
        guard engine.current?.generator == nil else { return "generator not removed" }
        engine.apply(.generator, "sphere")
        guard engine.current?.generator?.mesh == .sphere, engine.current?.generatorPreset == nil else { return "bare generator tool not loaded" }

        // Multiple generators: adding a second generator, moving it, and removing it.
        engine.selectDevice("camera")
        engine.apply(.generator, "plane")
        guard engine.current?.generators.count == 2 else { return "second generator not added" }
        guard let secondGen = engine.current?.generators[1], secondGen.type == "plane" else { return "second generator type mismatch" }

        // Plane width and height add polygons in the direction modified.
        let initialVerts = secondGen.vertexCount
        secondGen.bank["width"]?.setBase(20)
        secondGen.finishMeshBuild(device: engine.device)
        guard secondGen.vertexCount == initialVerts * 2 else {
            return "plane width didn't double polygons: \(secondGen.vertexCount) vs \(initialVerts * 2)"
        }
        secondGen.bank["height"]?.setBase(20)
        secondGen.finishMeshBuild(device: engine.device)
        guard secondGen.vertexCount == initialVerts * 4 else {
            return "plane height didn't double polygons again: \(secondGen.vertexCount) vs \(initialVerts * 4)"
        }
        secondGen.bank["width"]?.setBase(10)
        secondGen.bank["height"]?.setBase(10)
        secondGen.finishMeshBuild(device: engine.device)
        guard secondGen.vertexCount == initialVerts else {
            return "plane did not restore original polygon count: \(secondGen.vertexCount) vs \(initialVerts)"
        }
        engine.moveGenerator(key: secondGen.key, by: -1)
        guard engine.current?.generators.first?.key == secondGen.key else { return "generator not moved left" }
        engine.removeGenerator(key: secondGen.key)
        guard engine.current?.generators.count == 1 else { return "second generator not removed" }
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
        guard engine.current?.cameraLabel == "Drift", engine.current?.camera?["distance"]?.base == 9 else { return "camera preset not applied" }
        engine.apply(.palette, "palette", preset: "ice")
        guard engine.current?.paletteLabel == "Ice" else { return "palette preset not applied" }
        engine.removeInput("audio")
        guard engine.current?.hasAudioInput == false else { return "input not removed" }

        // Tool cardinality: audio/clock/camera/palette are single, generators/effects/LFOs/MIDI/webcams are many.
        guard Tools.cardinality(.input, "audio") == .one,
              Tools.cardinality(.input, "clock") == .one,
              Tools.cardinality(.camera, "orbit") == .one,
              Tools.cardinality(.palette, "palette") == .one,
              Tools.cardinality(.generator, "torus") == .many else { return "tool cardinality incorrect" }

        // Optional camera and palette removal and rendering without them.
        engine.removeCamera()
        guard engine.current?.camera == nil else { return "camera not removed" }
        _ = engine.renderOffscreen(engine.current!, frames: 2, snapshot: nil)
        engine.removePalette()
        guard engine.current?.palette == nil else { return "palette not removed" }
        _ = engine.renderOffscreen(engine.current!, frames: 2, snapshot: nil)

        // Restore camera and palette.
        engine.apply(.camera, "orbit")
        guard engine.current?.camera != nil else { return "camera not restored" }
        engine.apply(.palette, "palette")
        guard engine.current?.palette != nil else { return "palette not restored" }

        // Drag and drop: 'one' replaces, 'many' appends.
        engine.drop(.device(.camera, tool: "orbit", preset: "barrel-roll"), at: .replace(.camera))
        guard engine.current?.cameraLabel == "Barrel Roll" else { return "camera drop didn't replace" }

        // Multiple generators render on the same stage.
        let initialGenCount = engine.current?.generators.count ?? 0
        let firstGenType = engine.current?.generators.first?.type
        engine.selectDevice("generator")
        engine.drop(.device(.generator, tool: "torus", preset: nil), at: .append(.generator))
        guard engine.current?.generators.count == initialGenCount + 1 else { return "generator drop didn't append" }
        guard engine.current?.generators.first?.type == firstGenType else { return "generator drop replaced selected generator" }
        _ = engine.renderOffscreen(engine.current!, frames: 2, snapshot: nil)

        // Drop right on top of same tool replaces instead of appending.
        let genCountBefore = engine.current?.generators.count ?? 0
        engine.drop(.device(.generator, tool: "plane", preset: nil), at: .replaceDevice(key: "generator", kind: .generator, tool: "sphere"))
        guard engine.current?.generators.count == genCountBefore else { return "drop on a generator changed generator count" }
        guard engine.current?.generators.first?.type == "plane" else { return "drop on a generator didn't replace it" }

        if let secondKey = engine.current?.generators.last?.key { engine.removeGenerator(key: secondKey) }
        guard engine.current?.generators.count == initialGenCount else { return "second generator not removed" }

        // Native Undo / Redo support.
        engine.undoManager = UndoManager()
        let typesBeforeUndo = engine.current?.generators.map(\.type)
        engine.apply(.generator, "wheel")
        guard engine.canUndo else { return "cannot undo after apply" }
        engine.undo()
        guard engine.current?.generators.map(\.type) == typesBeforeUndo else { return "undo failed to remove the added generator" }
        guard engine.canRedo else { return "cannot redo after undo" }
        engine.redo()
        guard engine.current?.generators.last?.type == "wheel" else { return "redo failed to add the generator again" }

        // Scene deletion.
        let delURL = engine.store.scenesDir.appendingPathComponent("selfcheck-test-delete.json")
        let tempScene = SceneFile(name: "Temp Delete", inputs: [], modulators: [], camera: nil, palette: nil, generator: nil, effects: [], mappings: [])
        do {
            try tempScene.write(to: delURL)
            engine.refreshSceneList()
            guard engine.sceneURLs.contains(delURL) else { return "temp scene to delete not found" }
            engine.deleteScene(delURL)
            guard !engine.sceneURLs.contains(delURL) && !FileManager.default.fileExists(atPath: delURL.path) else {
                return "scene not deleted from disk"
            }
        } catch {
            return "failed to write temp scene for deletion check"
        }

        // Tool deletion via removeSelectedDevice
        engine.selectDevice("camera")
        engine.removeSelectedDevice()
        guard engine.current?.camera == nil else { return "selected camera not removed by removeSelectedDevice" }
        engine.apply(.camera, "orbit")

        guard engine.isDirty else { return "edits not marked unsaved" }
        guard (try? Data(contentsOf: presetURL)) == presetBefore else { return "a scene edit wrote to a preset file" }
        return nil
    }

    /// A red test frame stands in for the camera: it should come out of the webcam's
    /// processing and show up behind the mesh when the generator's video bg is up.
    private static func checkWebcam(engine: Engine, snapshotDir: URL?) -> String? {
        guard let url = engine.sceneURLs.first(where: { $0.lastPathComponent == "kaleido.json" }) else { return "test scene missing" }
        engine.load(url, animated: false)
        defer { engine.load(url, animated: false) }
        engine.apply(.input, "webcam")
        guard engine.current?.mappings.contains(where: { $0.source.hasPrefix("webcam.") }) == false else {
            return "new webcam mapped itself"
        }
        engine.addMapping(source: "webcam.webcam.video", target: "generator.texVideo")
        guard let added = engine.current, let first = added.webcams.first, first.key == "webcam.webcam",
              added.streamBindings["generator.texVideo"] === first.video, engine.selectedDevice == "webcam.webcam",
              added.mappings.first(where: { $0.source == "webcam.webcam.video" })?.kind == .video else {
            return "webcam video not mapped into the generator's Texture"
        }
        // Typed IO: video only into video inputs, values only into knobs.
        let count = added.mappings.count
        engine.addMapping(source: "webcam.webcam.video", target: "generator.spin")
        engine.addMapping(source: "audio.kick", target: "generator.texVideo")
        guard engine.current?.mappings.count == count else { return "mapped across kinds (video ↔ value)" }
        guard let scene = engine.current, let cam = scene.webcams.first,
              scene.streamBindings["generator.texVideo"] === cam.video,
              scene.streamInputs.contains(where: { $0.label == "Texture" }),
              // Kaleido's sphere and shards: Depth belongs to the Plane only.
              !scene.streamInputs.contains(where: { $0.label == "Depth" }) else { return "stream inputs: Texture missing, or Depth off the Plane" }
        guard cam.pipeline != nil, cam.bank["zoom"] != nil, cam.bank["bg"] != nil, cam.bank["mirror"]?.def.labels == ["Off", "Flip", "Fold", "Quad"] else {
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

        guard let gen = scene.generator, let bg = cam.bank["bg"], let tex = gen.bank["videoTex"] else {
            return "webcam or generator has no video knobs"
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
              engine.current?.mappings.first(where: { $0.target == "generator.texVideo" })?.problem == "Needs its Webcam in the chain",
              engine.current?.mappings.first(where: { $0.source == "webcam.webcam.motion" })?.problem == "Needs its Webcam in the chain" else {
            return "removing the webcam left its video or mapping active"
        }
        return nil
    }

    /// The depth field scene, with a test depth standing in for the model (near on the left
    /// half, far on the right): it should come out of the depth pass framed like the video
    /// (mirrored, so near on the right), raise the field, and stop when unmapped.
    private static func checkDepth(engine: Engine, snapshotDir: URL?) -> String? {
        let url: URL
        let temporaryURL: URL?
        if let existing = engine.sceneURLs.first(where: { $0.lastPathComponent == "05-depth-field.json" }) {
            url = existing
            temporaryURL = nil
        } else {
            let temp = engine.store.scenesDir.appendingPathComponent("selfcheck-depth.json")
            let sceneFile = SceneFile(
                name: "Self-Check Depth",
                inputs: [InputSpec(type: "audio", device: "system"), InputSpec(type: "clock"), InputSpec(type: "webcam", id: "webcam")],
                modulators: [],
                camera: CameraSlot(type: "orbit", params: ["distance": 7, "fov": 55, "height": 2.2, "lookY": -0.5]),
                palette: PaletteSlot(preset: "sonar", colors: ["#020A0D", "#0E4D5C", "#2EC4B6", "#FF9F1C", "#FFE8C2"]),
                generator: GeneratorSlot(type: "plane", params: ["depth": 2.2, "depthCut": 0.5, "fill": 0.9, "videoMap": 5, "videoTex": 0.7, "videoTint": 0.6]),
                effects: [EffectSpec(effect: "glitch", id: "glitch"), EffectSpec(effect: "glow", id: "glow"), EffectSpec(effect: "film", id: "film")],
                mappings: [
                    MappingSpec(source: "webcam.webcam.depth", target: "generator.depthVideo"),
                    MappingSpec(source: "webcam.webcam.video", target: "generator.texVideo")
                ]
            )
            do {
                try sceneFile.write(to: temp)
                engine.store.markSeen(temp)
                engine.refreshSceneList()
                url = temp
                temporaryURL = temp
            } catch {
                return "could not write selfcheck-depth scene"
            }
        }
        defer {
            if let temporaryURL {
                try? FileManager.default.removeItem(at: temporaryURL)
                engine.refreshSceneList()
            }
        }
        engine.load(url, animated: false)
        guard let scene = engine.current, let cam = scene.webcams.first, let gen = scene.generator else { return "depth scene didn't build" }
        guard gen.mesh == .plane, scene.streamBindings["generator.depthVideo"] === cam.depthVideo,
              cam.depthMapped, cam.feed.depthWanted, cam.depthPipeline != nil else {
            return "depth not mapped into the plane, or not running: \(engine.errors)"
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

        // Depth off: the plane goes flat, so the picture changes.
        let with = engine.averageColor(engine.renderer.history)
        gen.bank["depth"]?.setBase(0)
        _ = engine.renderOffscreen(scene, frames: 3, snapshot: snapshotDir?.appendingPathComponent("depth-plane-flat.png"))
        let without = engine.averageColor(engine.renderer.history)
        guard simd_length(with - without) > 0.003 else { return "depth didn't move the plane: \(with) vs \(without)" }

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

        if let problem = checkRates(engine: engine) {
            print("FAIL rates: \(problem)"); failures += 1
        } else {
            print("ok   rates (speed knobs integrate, no time × knob in shaders, generated names can't clash)")
        }

        if let problem = checkMath(engine: engine) {
            print("FAIL math: \(problem)"); failures += 1
        } else {
            print("ok   math (starts unmapped, no sync input, ops, value in through a mapping, unknown modulator fails)")
        }

        if let problem = checkMacro(engine: engine) {
            print("FAIL macro: \(problem)"); failures += 1
        } else {
            print("ok   macro (starts unmapped, three outputs follow their knobs, one knob drives several, remap by menu and click keeps settings, paused outputs 0)")
        }

        if let problem = checkCameras(engine: engine) {
            print("FAIL cameras: \(problem)"); failures += 1
        } else {
            print("ok   cameras (presets, poses, static, orbit snap, cutter trigger, unknown type fails)")
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

        if let problem = checkTransitions(engine: engine) {
            print("FAIL transitions: \(problem)"); failures += 1
        } else {
            print("ok   transitions (timing, outgoing and incoming scenes both drawn and blended, own cameras)")
        }

        if let problem = checkClockAudio(engine: engine) {
            print("FAIL clock: \(problem)"); failures += 1
        } else {
            print("ok   clock (follows audio only through Audio Out → Clock · Audio, typed, starts unmapped)")
        }

        if let problem = checkEncapsulation(engine: engine) {
            print("FAIL encapsulation: \(problem)"); failures += 1
        } else {
            print("ok   encapsulation (scenes own their Audio In and Clock, beat continues across a switch, no broadcast, hardware idle)")
        }

        if let problem = checkLowPoly(engine: engine) {
            print("FAIL low poly: \(problem)"); failures += 1
        } else {
            print("ok   low poly geos")
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

extension SelfCheck {
    /// Speed knobs flagged `rate` hand the shader their integrated value, so turning one never
    /// jumps the motion; and no shader multiplies time by a knob, which would.
    static func checkRates(engine: Engine) -> String? {
        let defs = ParamDef.parse(shaderSource: "// @param amount 0.5 0 1\n// @param spin 1 -2 2 rate\n// @param steps 2 1 4 int rate")
        guard defs.map(\.isRate) == [false, true, false] else { return "rate flag not parsed (or allowed on an int)" }
        let bank = ParamBank(defs: defs)
        bank.integrate(dt: 0.5)
        bank["spin"]!.live = 3
        bank.integrate(dt: 0.5)
        guard abs(bank["spin"]!.phase - 2) < 1e-6 else { return "rate phase not integrated: \(bank["spin"]!.phase)" }
        var packed: [Float] = []
        bank.withPacked { ptr, n in packed = Array(UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: Float.self), count: n / 4)) }
        guard packed == [0.5, 3, 2, 2] else { return "rate phase not packed after the params: \(packed)" }
        // Reloading with the same knob keeps the phase going.
        let reloaded = ParamBank(defs: defs, values: ["spin": 1], reuse: bank)
        guard reloaded["spin"]?.phase == 2 else { return "rate phase lost on reload" }

        let shaderDir = engine.store.commonShader.deletingLastPathComponent()
        let files = FileManager.default.enumerator(at: shaderDir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "metal" } ?? []
        let timesKnob = try! NSRegularExpression(pattern: #"f\.time\s*\*\s*p\.|p\.\w+\s*\*\s*f\.time"#)
        for url in files {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if timesKnob.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                return "\(url.lastPathComponent) multiplies f.time by a knob: flag it `rate` and read p.<name>Phase"
            }
        }

        let clashURL = FileManager.default.temporaryDirectory.appendingPathComponent("selfcheck-rate-clash.metal")
        defer { try? FileManager.default.removeItem(at: clashURL) }
        try? "// @param spin 1 -2 2 rate\n// @param spinPhase 0 0 1\nfragment float4 effect() { return 0; }\n"
            .write(to: clashURL, atomically: true, encoding: .utf8)
        do {
            _ = try ShaderCompiler(device: engine.device, commonURL: engine.store.commonShader).compile(clashURL)
            return "a param named like a generated phase compiled"
        } catch {}
        return nil
    }

    /// The Math modulator: added unmapped, its `a` knob takes a value through a mapping like any
    /// knob, and its output is the chosen op of `a` and `b`, 0...1.
    static func checkMath(engine: Engine) -> String? {
        let url = engine.store.scenesDir.appendingPathComponent("selfcheck-math.json")
        let file = SceneFile(name: "Self-check Math", inputs: [InputSpec(type: "clock")],
                             modulators: [ModulatorSpec(type: "lfo", id: "lfo")],
                             camera: nil, palette: nil, generator: nil, effects: [], mappings: [])
        do { try file.write(to: url) } catch { return "could not write the test scene" }
        engine.store.markSeen(url)
        engine.refreshSceneList()
        let back = engine.currentURL
        defer {
            if let back { engine.load(back, animated: false) }
            try? FileManager.default.removeItem(at: url)
            engine.refreshSceneList()
        }
        engine.load(url, animated: false)
        engine.apply(.modulation, "math")
        guard let scene = engine.current, let math = scene.modulators.first(where: { $0.id == "math" }),
              math.type == .math else { return "math not added" }
        guard !scene.mappings.contains(where: { $0.target.hasPrefix("mod.math.") || $0.source == "mod.math.out" }) else {
            return "math started mapped"
        }
        guard !scene.streamInputs.contains(where: { $0.key == "mod.math.sync" }),
              scene.streamInputs.contains(where: { $0.key == "mod.lfo.sync" }) else { return "math has a sync input (or the LFO lost its)" }
        guard let out = scene.outputs.first(where: { $0.key == "mod.math.out" }), !out.isBipolar else { return "no unipolar math output" }
        guard Tools.label(.modulation, "math") == "Math" else { return "math label" }

        var f = SignalFrame()
        f.dt = 0
        func run(_ op: Int, a: Float, b: Float) -> Float {
            math.bank["op"]!.setBase(Float(op)); math.bank["a"]!.setBase(a); math.bank["b"]!.setBase(b)
            scene.modulate(f)  // knobs settle
            scene.modulate(f)  // output reads them
            return out.value
        }
        let cases: [(op: Int, a: Float, b: Float, want: Float)] = [
            (0, 0.8, 0.5, 0.4), (1, 0.8, 0.5, 1), (2, 0.8, 0.5, 0.3), (3, 0.2, 0.5, 0.3), (4, 0.8, 0.5, 0.5),
            (5, 0.2, 0.5, 0.5), (6, 0.25, 0.5, 0.25), (7, 0.6, 0.5, 1), (7, 0.4, 0.5, 0), (8, 0.6, 1.0 / 14.0, 0.5), (8, 0.4, 0, 0),
            (9, 0.75, 1.0 / 7.0, 0.5), (10, 0.75, 1.0 / 7.0, 0.5), (11, 0.2, 0.5, 0.8),
        ]
        for c in cases {
            let v = run(c.op, a: c.a, b: c.b)
            guard abs(v - c.want) < 1e-3 else { return "\(MathParams.ops[c.op]) of \(c.a), \(c.b) is \(v), want \(c.want)" }
        }
        // A value mapped onto `a` reaches the output: a pulse on the downbeat, through A × 1.
        engine.current?.clock?.manager.seek(beat: 8)
        engine.addMapping(source: "clock.pulse", target: "mod.math.a")
        guard let s2 = engine.current, let m2 = s2.modulators.first(where: { $0.id == "math" }),
              let out2 = s2.outputs.first(where: { $0.key == "mod.math.out" }),
              s2.mappings.first(where: { $0.target == "mod.math.a" })?.isActive == true else { return "mapping onto math.a inactive" }
        m2.bank["a"]!.setBase(0); m2.bank["op"]!.setBase(0); m2.bank["b"]!.setBase(1)
        s2.modulate(f); s2.modulate(f)
        let a = m2.bank["a"]!.live
        guard a > 0.1, abs(out2.value - a) < 1e-4 else { return "mapped pulse did not reach math (a \(a), out \(out2.value))" }
        // Paused, it outputs 0.
        m2.enabled = false
        s2.modulate(f)
        guard out2.value == 0 else { return "paused math still outputs" }

        // An unknown modulator type fails, rather than turning into something else.
        var bad = file
        bad.modulators = [ModulatorSpec(type: "wobbler", id: "w")]
        guard engine.build(bad, reuse: nil) == nil, engine.errors["modulator"] != nil else { return "unknown modulator built" }
        return nil
    }

    /// The Macro modulator: added unmapped, three knobs stacked, each its own 0...1 output, so
    /// one knob mapped onto several drives them all.
    static func checkMacro(engine: Engine) -> String? {
        let url = engine.store.scenesDir.appendingPathComponent("selfcheck-macro.json")
        let file = SceneFile(name: "Self-check Macro", inputs: [], modulators: [],
                             camera: nil, palette: nil, generator: nil, effects: [], mappings: [])
        do { try file.write(to: url) } catch { return "could not write the test scene" }
        engine.store.markSeen(url)
        engine.refreshSceneList()
        let back = engine.currentURL
        defer {
            if let back { engine.load(back, animated: false) }
            try? FileManager.default.removeItem(at: url)
            engine.refreshSceneList()
        }
        engine.load(url, animated: false)
        engine.apply(.modulation, "macro")
        engine.apply(.modulation, "lfo")
        guard let scene = engine.current, let macro = scene.modulators.first(where: { $0.id == "macro" }),
              macro.type == .macro else { return "macro not added" }
        guard Tools.label(.modulation, "macro") == "Macro" else { return "macro label" }
        guard macro.bank.params.map(\.def.name) == ["macro1", "macro2", "macro3"] else { return "macro knobs wrong" }
        guard !scene.mappings.contains(where: { $0.target.hasPrefix("mod.macro.") || $0.source.hasPrefix("mod.macro.") }) else {
            return "macro started mapped"
        }
        guard !scene.streamInputs.contains(where: { $0.key == "mod.macro.sync" }) else { return "macro has a sync input" }
        let keys = ["mod.macro.macro1", "mod.macro.macro2", "mod.macro.macro3"]
        let outs = keys.compactMap { k in scene.outputs.first { $0.key == k } }
        guard outs.count == 3, outs.allSatisfy({ !$0.isBipolar && engine.kind(of: $0.key) == .value }) else {
            return "macro outputs missing or not unipolar values"
        }

        var f = SignalFrame()
        f.dt = 0
        macro.bank["macro1"]!.setBase(0.3); macro.bank["macro2"]!.setBase(0.7); macro.bank["macro3"]!.setBase(1)
        scene.modulate(f); scene.modulate(f)
        guard zip(outs.map(\.value), [Float(0.3), 0.7, 1]).allSatisfy({ abs($0 - $1) < 1e-4 }) else {
            return "macro outputs don't follow their knobs: \(outs.map(\.value))"
        }

        // One knob drives two: Macro 1 → LFO depth (up) and LFO phase (inverted, down).
        engine.addMapping(source: "mod.macro.macro1", target: "mod.lfo.depth")
        engine.addMapping(source: "mod.macro.macro1", target: "mod.lfo.phase")
        guard let s2 = engine.current, let m2 = s2.modulators.first(where: { $0.id == "macro" }),
              let lfo = s2.modulators.first(where: { $0.id == "lfo" }),
              let toDepth = s2.mappings.first(where: { $0.target == "mod.lfo.depth" }),
              let toPhase = s2.mappings.first(where: { $0.target == "mod.lfo.phase" }),
              toDepth.isActive, toPhase.isActive else { return "macro mappings inactive (a knob named depth must take values)" }
        toDepth.amount = 1
        toPhase.amount = 0.5; toPhase.invert = true
        lfo.bank["depth"]!.setBase(0); lfo.bank["phase"]!.setBase(1)
        m2.bank["macro1"]!.setBase(0.4)
        s2.modulate(f); s2.modulate(f)
        guard abs(lfo.bank["depth"]!.live - 0.4) < 1e-3, abs(lfo.bank["phase"]!.live - 0.8) < 1e-3 else {
            return "macro didn't drive both knobs (depth \(lfo.bank["depth"]!.live), phase \(lfo.bank["phase"]!.live))"
        }
        // Remapping moves a mapping to another knob and keeps its settings.
        engine.retargetMapping(toPhase, to: "mod.lfo.hz")
        guard let s3 = engine.current, !s3.mappings.contains(where: { $0.target == "mod.lfo.phase" }),
              let moved = s3.mappings.first(where: { $0.source == "mod.macro.macro1" && $0.target == "mod.lfo.hz" }),
              moved.isActive, moved.amount == 0.5, moved.invert, s3.mappings.count == 2 else { return "remap lost the mapping or its settings" }
        // Not onto a target it already feeds.
        engine.retargetMapping(moved, to: "mod.lfo.depth")
        guard engine.current?.mappings.contains(where: { $0.target == "mod.lfo.hz" }) == true else { return "remapped onto a duplicate" }
        // Click to remap: the source waits like mapping, and the next knob clicked takes the mapping.
        guard let waiting = engine.current?.mappings.first(where: { $0.target == "mod.lfo.hz" }) else { return "mapping lost" }
        engine.startRemap(waiting)
        guard engine.mapSource == "mod.macro.macro1", engine.remapping != nil else { return "remap mode not started" }
        guard engine.knobClicked("mod.lfo.shape", keepMapping: true) else { return "remap click not used" }
        guard let s4 = engine.current, engine.mapSource == nil, engine.remapping == nil,
              !s4.mappings.contains(where: { $0.target == "mod.lfo.hz" }),
              let clicked = s4.mappings.first(where: { $0.target == "mod.lfo.shape" }), clicked.invert, clicked.amount == 0.5,
              s4.mappings.count == 2 else { return "click-to-remap didn't move the mapping once" }
        // Mapping another output cancels a remap.
        engine.startRemap(clicked)
        engine.mapSource = "mod.macro.macro2"
        guard engine.remapping == nil else { return "remap survived mapping another output" }
        engine.mapSource = nil
        // Paused, it outputs 0.
        guard let m3 = engine.current?.modulators.first(where: { $0.id == "macro" }) else { return "macro lost" }
        m3.enabled = false
        engine.current?.modulate(f)
        guard m3.outputs.allSatisfy({ $0.value == 0 }) else { return "paused macro still outputs" }
        return nil
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
    /// The scene's tools run as they would live: Audio In analyses `offlineAudio` (written into
    /// the capture's ring, which is silent without it), the Clock advances, then the mappings.
    func renderOffscreen(_ scene: RenderScene, frames: Int, snapshot: URL?) -> Double {
        var gpu = 0.0
        // Scenes on the same source share its capture, so the audio goes into that one ring.
        let ring = scene.audioIn?.capture.ring
        if offlineAudio == nil { ring?.reset() }
        var audioPos = 0
        for i in 0..<frames {
            offlineTime += 1.0 / 60
            let signals = SignalFrame(time: Float(i) / 60, dt: 1 / 60, now: offlineTime)
            if let (samples, rate) = offlineAudio {
                ring?.setSampleRate(rate)
                let n = Int(rate / 60)
                ring?.write(frames: n) { k in samples[(audioPos + k) % samples.count] }
                audioPos += n
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

    /// Renders crossfade frames between two scenes at a fixed progress, into `renderer.history`.
    func renderTransition(from a: RenderScene, to b: RenderScene, progress: Float, frames: Int) {
        if offlineAudio == nil { for s in [a, b] { s.audioIn?.capture.ring.reset() } }
        for i in 0..<frames {
            offlineTime += 1.0 / 60
            let signals = SignalFrame(time: Float(i) / 60, dt: 1 / 60, now: offlineTime)
            a.modulate(signals)
            b.modulate(signals)
            var f = FrameUniforms()
            f.time = signals.time; f.dt = signals.dt
            let cmd = renderer.queue.makeCommandBuffer()!
            renderer.encodeTransition(cmd, from: a, to: b, progress: progress, frame: &f)
            cmd.commit()
            cmd.waitUntilCompleted()
            if let e = cmd.error { print("  GPU error: \(e)") }
        }
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
