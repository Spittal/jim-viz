import AppKit
import Metal
import Observation

/// App state on the main thread. Builds `RenderScene`s from scene files and hands them
/// to the render thread.
@Observable
final class Engine {
    @ObservationIgnored let device: MTLDevice
    @ObservationIgnored let renderer: Renderer
    @ObservationIgnored let loop: RenderLoop
    @ObservationIgnored let store = ContentStore()
    // Hardware, shared by every scene's devices and running only while a scene on screen
    // uses it (`activateHardware`). Tools in the chain own their settings and analysis.
    /// The audio sources Audio Ins listen to, one capture per source in use.
    let audioCaptures = AudioCaptures()
    /// MIDI controllers, for MIDI Inputs.
    let midi = MIDIEngine()
    /// Cameras, and a feed per camera in use.
    let webcams: WebcamManager
    /// Looping video files in use.
    let videos: VideoManager
    /// Picture files in use.
    let pictures: PictureManager
    @ObservationIgnored private let compiler: ShaderCompiler
    @ObservationIgnored let output: OutputController
    /// False until launch finishes, and always in the headless self-check.
    @ObservationIgnored private var hardwareReady = false

    private(set) var sceneURLs: [URL] = []
    /// Display names from each scene file's `name`, falling back to the file name.
    private(set) var sceneNames: [URL: String] = [:]
    /// The scene being renamed in the list.
    var renamingScene: URL?
    private(set) var currentURL: URL?
    private(set) var current: RenderScene?
    @ObservationIgnored private var sceneFile: SceneFile?

    /// Errors keyed by source file, so fixing a file clears its message.
    private(set) var errors: [String: String] = [:]
    private(set) var info: String = ""

    // Stats, refreshed at UI rate.
    private(set) var fps: Double = 0
    private(set) var gpuMs: Double = 0

    var isTransitioning: Bool { loop.transition.isTransitioning }
    @ObservationIgnored private var pendingScene: (url: URL, file: SceneFile, scene: RenderScene)?

    @ObservationIgnored private let sceneLock = NSLock()
    @ObservationIgnored private var renderScene: RenderScene?
    @ObservationIgnored private var cache: [URL: CacheEntry] = [:]
    @ObservationIgnored private var uiTimer: Timer?
    /// Audio fed to offscreen renders by the self-check, through the capture's ring.
    @ObservationIgnored var offlineAudio: (samples: [Float], rate: Double)?
    /// Simulated host time of offscreen renders, so it keeps counting across them.
    @ObservationIgnored var offlineTime: Double = 0

    private enum CacheEntry {
        case generator(CompiledShader, mesh: MTLRenderPipelineState, blend: MTLRenderPipelineState?, background: MTLRenderPipelineState)
        case effect(CompiledShader, MTLRenderPipelineState)
        case lens(CompiledShader, MTLRenderPipelineState)
        case webcam(CompiledShader, MTLRenderPipelineState, depth: MTLRenderPipelineState)
    }

    init(headless: Bool = false) {
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal is not available") }
        self.device = device
        renderer = Renderer(device: device)
        loop = RenderLoop(renderer: renderer)
        compiler = ShaderCompiler(device: device, commonURL: store.commonShader)
        webcams = WebcamManager(device: device)
        webcams.captureEnabled = !headless
        videos = VideoManager(device: device)
        pictures = PictureManager(device: device)
        output = OutputController(device: device, loop: loop)
        loop.sceneProvider = { [unowned self] in
            self.sceneLock.lock(); defer { self.sceneLock.unlock() }
            return self.renderScene
        }
        midi.onMessage = { [weak self] msg in
            self?.handleMIDI(msg)
        }

        refreshSceneList()
        if headless {
            enableAutoSave = false
            return
        }
        if let first = sceneURLs.first { load(first) }
        store.watch { [weak self] changed in self?.filesChanged(changed) }
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.uiTick() }
        // Windows must not be created until SwiftUI has opened the main window.
        launchObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.hardwareReady = true
                self?.midi.refreshEndpoints()
                self?.audioCaptures.refreshInputDevices()
                self?.webcams.start()
                self?.activateHardware()
                self?.output.start()
                self?.applyLaunchArguments()
            }
        }
    }
    @ObservationIgnored private var launchObserver: NSObjectProtocol?

    /// `--output windowed` or `--output fullscreen` (projector, or main screen if none).
    private func applyLaunchArguments() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--output"), i + 1 < args.count else { return }
        switch args[i + 1] {
        case "windowed": output.setMode(.windowed)
        case "fullscreen": if let s = output.preferredScreen { output.setMode(.fullscreen(s.id)) }
        default: break
        }
    }

    var errorSummary: String? {
        errors.sorted { $0.key < $1.key }.first.map { "\($0.key): \($0.value)" }
    }

    var contentRoot: URL { store.root }

    // MARK: Scenes

    /// True after an edit until saved.
    private(set) var isDirty = false
    /// The chain item being dragged, set when a drag starts in this app.
    @ObservationIgnored var activeDrag: ChainDrag?

    var scenePendingDeletion: URL?

    @ObservationIgnored var undoManager: UndoManager?
    @ObservationIgnored var enableAutoSave: Bool = !CommandLine.arguments.contains("--check")
    @ObservationIgnored private var autoSaveWorkItem: DispatchWorkItem?

    var canUndo: Bool { undoManager?.canUndo ?? false }
    var canRedo: Bool { undoManager?.canRedo ?? false }

    func undo() {
        undoManager?.undo()
    }

    func redo() {
        undoManager?.redo()
    }

    func currentSnapshot() -> SceneFile? {
        guard var file = sceneFile, let scene = current else { return nil }
        syncValues(from: scene, into: &file)
        return file
    }

    func recordUndo(name: String, before: SceneFile) {
        guard let um = undoManager else { return }
        um.setActionName(name)
        um.registerUndo(withTarget: self) { engine in
            if let current = engine.currentSnapshot() {
                engine.recordUndo(name: name, before: current)
            }
            engine.restoreState(before, actionName: "Undo: \(name)")
        }
    }

    func restoreState(_ file: SceneFile, actionName: String? = nil) {
        guard let currentScene = current else { return }
        if let rebuilt = build(file, reuse: currentScene) {
            sceneFile = file
            install(rebuilt)
            isDirty = true
            if let actionName { info = actionName }
            scheduleAutoSave()
        }
    }

    func scheduleAutoSave(delay: TimeInterval = 0.5) {
        isDirty = true
        guard enableAutoSave else { return }
        autoSaveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isDirty else { return }
            self.saveCurrent()
        }
        autoSaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func flushAutoSave() {
        if isDirty && enableAutoSave {
            autoSaveWorkItem?.cancel()
            autoSaveWorkItem = nil
            saveCurrent()
        }
    }

    // MARK: Mapping state

    /// Shows the mappings inspector on the right.
    var showInspector = UserDefaults.standard.object(forKey: "inspector.visible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInspector, forKey: "inspector.visible") }
    }
    /// An output waiting to be mapped: the next knob clicked receives it.
    var mapSource: String? {
        didSet { if remapping?.source != mapSource { remapping = nil } }
    }
    /// A mapping waiting to be moved: the next knob (or input) clicked becomes its target.
    /// Set through `startRemap`, which also puts its source in `mapSource`, so knobs light up as
    /// when mapping; cancelling or mapping something else clears it.
    private(set) var remapping: MappingRuntime?
    /// The last knob clicked or turned, highlighted in the inspector.
    var selectedTarget: String?
    /// The device selected in the chain, by chain key (`audio`, `clock`, `mod.<id>`, `camera`,
    /// `palette`, `generator`, `post.<id>`). The inspector shows its outputs and mappings.
    var selectedDevice: String?

    /// Folded devices, by scene file and chain key. Kept for the session, not saved in the scene.
    private var collapsed: Set<String> = []

    func isCollapsed(_ key: String) -> Bool { collapsed.contains("\(currentURL?.path ?? ""):\(key)") }

    func toggleCollapsed(_ key: String) {
        let k = "\(currentURL?.path ?? ""):\(key)"
        if collapsed.contains(k) { collapsed.remove(k) } else { collapsed.insert(k) }
    }

    /// Devices showing their IO columns (inputs left, outputs right), by scene file and chain
    /// key. Kept for the session, like folding.
    private var ioShown: Set<String> = []

    func isIOShown(_ key: String) -> Bool { ioShown.contains("\(currentURL?.path ?? ""):\(key)") }

    func toggleIO(_ key: String) {
        let k = "\(currentURL?.path ?? ""):\(key)"
        if ioShown.contains(k) { ioShown.remove(k) } else { ioShown.insert(k) }
    }

    /// Selects a device, unless mapping or learning, where clicks land on knobs in other devices
    /// and the inspector should stay on the device being mapped from.
    func selectDevice(_ key: String?) {
        guard mapSource == nil, selectedDevice != key else { return }
        selectedDevice = key
    }
    /// The knob an output is being dragged over.
    var dropKnob: String?

    func refreshSceneList() {
        sceneURLs = store.sceneURLs()
        struct Named: Decodable { let name: String? }
        var names: [URL: String] = [:]
        for url in sceneURLs {
            let decoded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Named.self, from: $0) }
            names[url] = decoded?.name ?? url.deletingPathExtension().lastPathComponent
        }
        if names != sceneNames { sceneNames = names }
        if tools.isEmpty { refreshTools() }
    }

    func sceneName(_ url: URL) -> String { sceneNames[url] ?? url.deletingPathExtension().lastPathComponent }

    /// Renames a scene: its `name`, and its file to match (`Big Drop` → `big-drop.json`).
    /// For the current scene, unsaved edits stay unsaved; only the name is written.
    func renameScene(_ url: URL, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        renamingScene = nil
        // An unchanged name does nothing (the file keeps its name even if it doesn't match).
        guard !name.isEmpty, name != sceneName(url) else { return }
        guard var onDisk = try? SceneFile.load(url) else { errors["rename"] = "could not read \(url.lastPathComponent)"; return }
        let oldSlug = url.deletingPathExtension().lastPathComponent
        let taken = Set(sceneURLs.map { $0.deletingPathExtension().lastPathComponent }).subtracting([oldSlug])
        var slug = slugify(name), n = 2
        while taken.contains(slug) { slug = "\(slugify(name))-\(n)"; n += 1 }
        let dest = url.deletingLastPathComponent().appendingPathComponent("\(slug).json")
        onDisk.name = name
        do {
            try onDisk.write(to: dest)
            store.markSeen(dest)
            if dest.standardizedFileURL != url.standardizedFileURL { try FileManager.default.removeItem(at: url) }
            errors["rename"] = nil
        } catch {
            errors["rename"] = "rename failed: \(error.localizedDescription)"
            return
        }
        if url == currentURL, var file = sceneFile, let scene = current {
            syncValues(from: scene, into: &file)
            file.name = name
            currentURL = dest
            sceneFile = file
            if let rebuilt = build(file, reuse: scene) { install(rebuilt) }
        }
        refreshSceneList()
        info = "Renamed to \(name)"
    }

    func load(_ url: URL, animated: Bool = true) {
        do {
            let file = try SceneFile.load(url)
            errors[url.lastPathComponent] = nil
            let isReload = url == currentURL
            guard let nextScene = build(file, reuse: isReload ? current : nil) else { return }
            autoSaveWorkItem?.cancel()
            autoSaveWorkItem = nil
            isDirty = false
            undoManager?.removeAllActions()
            if animated, let currentScene = current, !isReload {
                pendingScene = (url, file, nextScene)
                activateHardware()
                loop.transition.start(from: currentScene, to: nextScene, now: CACurrentMediaTime())
                info = "Loaded \(file.name)"
            } else {
                sceneFile = file
                currentURL = url
                pendingScene = nil
                install(nextScene)
                info = "Loaded \(file.name)"
            }
        } catch {
            errors[url.lastPathComponent] = describe(error)
        }
    }

    func saveCurrent() {
        guard let url = currentURL, var file = sceneFile, let scene = current else { return }
        autoSaveWorkItem?.cancel()
        autoSaveWorkItem = nil
        syncValues(from: scene, into: &file)
        do {
            try file.write(to: url)
            store.markSeen(url)
            sceneFile = file
            isDirty = false
            info = "Saved \(url.lastPathComponent)"
        } catch {
            errors[url.lastPathComponent] = "save failed: \(error.localizedDescription)"
        }
    }

    func deleteScene(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            errors[url.lastPathComponent] = nil
            info = "Deleted \(sceneName(url))"
            let wasCurrent = (url == currentURL)
            refreshSceneList()
            if wasCurrent {
                if let nextURL = sceneURLs.first {
                    load(nextURL, animated: false)
                } else {
                    current = nil
                    currentURL = nil
                    sceneFile = nil
                    isDirty = false
                }
            }
        } catch {
            errors["delete"] = "delete failed: \(error.localizedDescription)"
        }
    }

    func stepScene(_ delta: Int) {
        guard !sceneURLs.isEmpty else { return }
        let idx = currentURL.flatMap { sceneURLs.firstIndex(of: $0) } ?? -1
        load(sceneURLs[(idx + delta + sceneURLs.count) % sceneURLs.count])
    }

    /// Creates an empty scene: Audio In, Clock and a static camera; no palette, generator or effects.
    func createNewScene() {
        let taken = Set(sceneURLs.map { $0.deletingPathExtension().lastPathComponent })
        var name = "Untitled Scene", n = 1
        while taken.contains(slugify(name)) { n += 1; name = "Untitled Scene \(n)" }
        let file = SceneFile(
            name: name,
            inputs: [InputSpec(type: "audio", device: Self.defaultAudioSource.key), InputSpec(type: "clock")],
            modulators: [],
            camera: cameraSlot(CameraRig.still.rawValue, preset: "front"),
            palettes: [],
            generators: [],
            effects: [],
            mappings: [])
        let url = store.scenesDir.appendingPathComponent("\(slugify(name)).json")
        do {
            try file.write(to: url)
            store.markSeen(url)
            refreshSceneList()
            load(url, animated: false)
            info = "New scene. Drag a generator and effects in from the browser."
        } catch {
            errors["new scene"] = error.localizedDescription
        }
    }

    // MARK: Composition

    /// Every tool and its presets, for the browser. Refreshed when Content changes.
    private(set) var tools: [Tool] = []

    var availableEffects: [String] { store.availableEffects() }

    func refreshTools() { tools = Tools.all(store) }

    /// Display name of a preset, falling back to its tool's name.
    func presetName(_ kind: DeviceKind, _ tool: String, _ preset: String?) -> String? {
        guard let preset else { return nil }
        return tools.first { $0.kind == kind && $0.name == tool }?.presets.first { $0.id == preset }?.name ?? humanize(preset)
    }

    private func cameraSlot(_ tool: String, preset id: String?) -> CameraSlot {
        // Every knob gets a value, so nothing carries over from the previous camera.
        let defs = CameraRig(rawValue: tool)?.defs ?? []
        var params = Dictionary(uniqueKeysWithValues: defs.map { ($0.name, $0.defaultValue) })
        if let id, let p = store.preset(.camera, tool, id) { for (k, v) in p.params ?? [:] { params[k] = v } }
        return CameraSlot(type: tool, preset: id, params: params)
    }

    private func lensSlot(_ tool: String, preset id: String?) -> LensSlot {
        LensSlot(type: tool, preset: id, params: id.flatMap { store.preset(.lens, tool, $0)?.params })
    }

    private func paletteColors(preset id: String?) -> [String] {
        id.flatMap { store.preset(.palette, "palette", $0)?.colors } ?? Tools.defaultPalette
    }

    /// Adds a tool to the chain, optionally loaded with one of its presets. Camera and lens
    /// replace what is there; palettes, generators, modulators and effects insert at `index` or append;
    /// inputs are added (one Audio In and one Clock, any number of the rest). A preset's values
    /// are copied in; the preset file is never touched.
    func apply(_ kind: DeviceKind, _ tool: String, preset: String? = nil, at index: Int? = nil, replaceSelected: Bool = true) {
        let label = presetName(kind, tool, preset) ?? Tools.label(kind, tool)
        let cardinality = Tools.cardinality(kind, tool)
        switch kind {
        case .input where tool == "midi":
            var key = ""
            edit("Added MIDI Input\(preset.map { " (\($0))" } ?? "")") { file in
                let id = Self.uniqueID(tool, taken: Set(file.inputs.compactMap(\.id)))
                file.inputs.append(InputSpec(type: tool, id: id, device: preset))
                key = "midi.\(id)"
            }
            // A new MIDI Input starts learning, with the inspector open to show what it learns.
            current?.learnMIDI(key)
            selectDevice(key)
            showInspector = true
        case .input where tool == "webcam" || tool == "video" || tool == "picture":
            var key = ""
            let toolLabel = Tools.label(kind, tool)
            edit("Added \(toolLabel)\(preset.map { " (\($0))" } ?? "")") { file in
                let id = Self.uniqueID(tool, taken: Set(file.inputs.compactMap(\.id)))
                let i = file.inputs.lastIndex { !$0.isMIDI }.map { $0 + 1 } ?? 0
                file.inputs.insert(InputSpec(type: tool, id: id, device: tool == "webcam" ? preset : nil,
                                             file: tool == "webcam" ? nil : preset), at: i)
                key = "\(tool).\(id)"
            }
            selectDevice(key)
            showInspector = true
        case .input:
            if cardinality == .one, sceneFile?.inputs.contains(where: { $0.type == tool }) == true {
                // A source picked for the Audio In already there switches it.
                if tool == "audio", let source = preset.flatMap(AudioCapture.Source.init(key:)) {
                    setAudioSource(source); selectDevice(tool); return
                }
                info = "\(label) is already in the chain"; selectDevice(tool); return
            }
            edit("Added \(label)") { file in
                // Audio In first, then Clock, then MIDI inputs. Audio In's presets are its sources.
                let i = tool == "audio" ? 0 : file.inputs.prefix { $0.type == "audio" }.count
                let device = tool == "audio" ? preset ?? Self.defaultAudioSource.key : nil
                file.inputs.insert(InputSpec(type: tool, device: device), at: i)
            }
            selectDevice(tool)
        case .camera:
            let slot = cameraSlot(tool, preset: preset)
            edit("Camera: \(label)") { $0.camera = slot }
            selectDevice("camera")
        case .lens:
            let slot = lensSlot(tool, preset: preset)
            edit("Lens: \(label)") { $0.lens = slot }
            selectDevice(LensRuntime.key)
        case .palette:
            // A preset dropped while a palette is selected recolours that one; otherwise it adds.
            if replaceSelected, preset != nil, let selected = selectedDevice,
               sceneFile?.palettes.contains(where: { $0.key == selected }) == true {
                replacePalette(key: selected, preset: preset)
                return
            }
            var key = "palette"
            edit("Added Palette: \(label)") { file in
                let id = file.palettes.isEmpty ? nil : Self.uniqueID(tool, taken: Set(file.palettes.compactMap(\.id) + ["palette"]))
                let slot = PaletteSlot(id: id, preset: preset, colors: paletteColors(preset: preset))
                let i = min(max(index ?? file.palettes.count, 0), file.palettes.count)
                file.palettes.insert(slot, at: i)
                key = slot.key
            }
            selectDevice(key)
        case .generator:
            let p = preset.flatMap { store.preset(.generator, tool, $0) }
            var key = "generator"
            edit("Generator: \(label)") { file in
                // A preset dropped while a generator is selected replaces that one; otherwise it adds.
                if replaceSelected, preset != nil, let selected = self.selectedDevice,
                   let idx = file.generators.firstIndex(where: { $0.key == selected }) {
                    file.generators[idx].type = tool
                    file.generators[idx].preset = preset
                    file.generators[idx].params = p?.params
                    key = selected
                } else {
                    let id = file.generators.isEmpty ? nil : Self.uniqueID(tool, taken: Set(file.generators.compactMap(\.id) + ["generator"]))
                    let slot = GeneratorSlot(id: id, type: tool, preset: preset, params: p?.params)
                    let i = min(max(index ?? file.generators.count, 0), file.generators.count)
                    file.generators.insert(slot, at: i)
                    key = slot.key
                }
            }
            selectDevice(key)
        case .modulation:
            let params = preset.flatMap { store.preset(.modulation, tool, $0)?.params }
            var key = ""
            edit("Added \(label)") { file in
                let id = Self.uniqueID(tool, taken: Set(file.modulators.map(\.id)))
                let spec = ModulatorSpec(type: tool, id: id, preset: preset, params: params)
                let i = min(max(index ?? file.modulators.count, 0), file.modulators.count)
                file.modulators.insert(spec, at: i)
                key = "mod.\(id)"
            }
            selectDevice(key)
        case .effect:
            let params = preset.flatMap { store.preset(.effect, tool, $0)?.params }
            var key = ""
            edit("Added \(label)") { file in
                let id = Self.uniqueID(tool, taken: Set(file.effects.map { $0.id ?? $0.effect }))
                let spec = EffectSpec(effect: tool, id: id, preset: preset, params: params)
                let i = min(max(index ?? file.effects.count, 0), file.effects.count)
                file.effects.insert(spec, at: i)
                key = "post.\(id)"
            }
            selectDevice(key)
        }
    }

    /// A palette's name in the chain: "Palette" for the first, "Palette 2" for `palette2`.
    static func paletteTitle(_ id: String?) -> String {
        guard let id else { return "Palette" }
        return humanize(id).replacingOccurrences(of: "([A-Za-z])([0-9])", with: "$1 $2", options: .regularExpression)
    }

    /// `glow`, then `glow2`, `glow3`…
    private static func uniqueID(_ base: String, taken: Set<String>) -> String {
        var id = base, n = 2
        while taken.contains(id) { id = "\(base)\(n)"; n += 1 }
        return id
    }

    /// Removes an input by chain key: `audio`, `clock` or `mod.<id>`.
    func removeInput(_ key: String) {
        let name = deviceName(key)
        if selectedDevice == key { selectDevice(nil) }
        edit("Removed \(name)") { $0.inputs.removeAll { $0.deviceKey == key } }
    }

    func removeCamera() {
        if selectedDevice == "camera" { selectDevice(nil) }
        edit("Removed Camera") { $0.camera = nil }
    }

    func removeLens() {
        if selectedDevice == LensRuntime.key { selectDevice(nil) }
        edit("Removed Lens") { $0.lens = nil }
    }

    func removePalette(key: String) {
        if selectedDevice == key { selectDevice(nil) }
        edit("Removed \(deviceName(key))") { $0.palettes.removeAll { $0.key == key } }
    }

    /// Recolours a palette from a preset; its inputs stay as they are.
    func replacePalette(key: String, preset: String?) {
        let label = presetName(.palette, "palette", preset) ?? "Palette"
        edit("Palette: \(label)") { file in
            guard let idx = file.palettes.firstIndex(where: { $0.key == key }) else { return }
            file.palettes[idx].preset = preset
            file.palettes[idx].colors = paletteColors(preset: preset)
        }
        selectDevice(key)
    }

    func removeModulator(id: String) {
        edit("Removed \(id)") { $0.modulators.removeAll { $0.id == id } }
    }

    func replaceGenerator(key: String, tool: String, preset: String?) {
        let p = preset.flatMap { store.preset(.generator, tool, $0) }
        let label = presetName(.generator, tool, preset) ?? Tools.label(.generator, tool)
        edit("Generator: \(label)") { file in
            guard let idx = file.generators.firstIndex(where: { $0.key == key }) else { return }
            file.generators[idx].type = tool
            file.generators[idx].preset = preset
            file.generators[idx].params = p?.params
        }
        selectDevice(key)
    }

    func replaceEffect(id: String, tool: String, preset: String?) {
        let params = preset.flatMap { store.preset(.effect, tool, $0)?.params }
        let label = presetName(.effect, tool, preset) ?? Tools.label(.effect, tool)
        edit("Effect: \(label)") { file in
            guard let idx = file.effects.firstIndex(where: { ($0.id ?? $0.effect) == id }) else { return }
            file.effects[idx] = EffectSpec(effect: tool, id: id, preset: preset, enabled: file.effects[idx].enabled, params: params)
        }
        selectDevice("post.\(id)")
    }

    func replaceModulator(id: String, tool: String, preset: String?) {
        let params = preset.flatMap { store.preset(.modulation, tool, $0)?.params }
        let label = presetName(.modulation, tool, preset) ?? Tools.label(.modulation, tool)
        edit("Modulator: \(label)") { file in
            guard let idx = file.modulators.firstIndex(where: { $0.id == id }) else { return }
            file.modulators[idx] = ModulatorSpec(type: tool, id: id, preset: preset, enabled: file.modulators[idx].enabled, params: params)
        }
        selectDevice("mod.\(id)")
    }

    func replaceInput(key: String, tool: String, preset: String?) {
        let label = presetName(.input, tool, preset) ?? Tools.label(.input, tool)
        edit("Input: \(label)") { file in
            guard let idx = file.inputs.firstIndex(where: { $0.deviceKey == key }) else { return }
            file.inputs[idx].device = preset
            file.inputs[idx].channelPair = nil
        }
        selectDevice(key)
    }

    /// Moves an LFO one place left (-1) or right (+1) in the Modulation section.
    func moveModulator(id: String, by offset: Int) {
        edit("Moved \(id)") { file in
            guard let from = file.modulators.firstIndex(where: { $0.id == id }) else { return }
            let to = min(max(from + offset, 0), file.modulators.count - 1)
            file.modulators.swapAt(from, to)
        }
    }

    func removeGenerator(key: String = "generator") {
        if selectedDevice == key { selectDevice(nil) }
        edit("Removed generator") { $0.generators.removeAll { $0.key == key } }
    }

    func moveGenerator(key: String, by offset: Int) {
        edit("Moved generator") { file in
            guard let from = file.generators.firstIndex(where: { $0.key == key }) else { return }
            file.generators.swapAt(from, min(max(from + offset, 0), file.generators.count - 1))
        }
    }

    func removeEffect(id: String) {
        edit("Removed \(id)") { $0.effects.removeAll { ($0.id ?? $0.effect) == id } }
    }

    func removeSelectedDevice() {
        guard let key = selectedDevice else { return }
        selectDevice(nil)
        if key == "camera" {
            removeCamera()
        } else if key == LensRuntime.key {
            removeLens()
        } else if key == "palette" || key.hasPrefix("palette.") {
            removePalette(key: key)
        } else if key == "audio" || key == "clock" || key.hasPrefix("midi.") || key.hasPrefix("webcam.") || key.hasPrefix("video.") || key.hasPrefix("picture.") {
            removeInput(key)
        } else if key.hasPrefix("mod.") {
            let id = String(key.dropFirst(4))
            removeModulator(id: id)
        } else if key.hasPrefix("generator") {
            removeGenerator(key: key)
        } else if key.hasPrefix("post.") {
            let id = String(key.dropFirst(5))
            removeEffect(id: id)
        }
    }

    /// Deletes whichever item is currently highlighted: a selected tool, or prompts to delete the active scene.
    func deleteHighlighted() {
        if selectedDevice != nil {
            removeSelectedDevice()
        } else if let url = currentURL {
            scenePendingDeletion = url
        }
    }

    /// Moves an effect so it lands before the effect currently at `index` (or at the end).
    func moveEffect(id: String, to index: Int) {
        edit("Moved \(id)") { file in
            guard let from = file.effects.firstIndex(where: { ($0.id ?? $0.effect) == id }) else { return }
            let spec = file.effects.remove(at: from)
            let dest = index > from ? index - 1 : index
            file.effects.insert(spec, at: min(max(dest, 0), file.effects.count))
        }
    }

    /// Applies a structural edit to the in-memory scene, keeping knob values, and rebuilds.
    private func edit(_ message: String, _ change: (inout SceneFile) -> Void) {
        guard var file = sceneFile, let scene = current else { return }
        syncValues(from: scene, into: &file)
        let stateBefore = file
        change(&file)
        if let rebuilt = build(file, reuse: scene) {
            recordUndo(name: message, before: stateBefore)
            sceneFile = file
            install(rebuilt)
            isDirty = true
            info = message
            scheduleAutoSave()
        }
    }

    // MARK: Mappings

    /// Routes an output to an input it connects to: a value output to a knob (a knob can take
    /// any number), a trigger or value output to a trigger input (any number too), or a stream
    /// (video, spectrum, palette) to a stream input of that kind (each takes one; mapping
    /// another replaces it).
    func addMapping(source: String, target: String) {
        let label = "\(sourceLabel(source)) → \(targetLabel(target))"
        let sourceKind = kind(of: source), targetKind = kind(of: target)
        guard sourceKind.connects(to: targetKind) else {
            info = sourceKind == .value ? "\(targetLabel(target)) takes \(targetKind.noun), not values"
                                        : "\(sourceLabel(source)) is \(sourceKind.noun): map it onto a \(sourceKind == .trigger ? "trigger" : sourceKind.noun) input"
            return
        }
        let stream = sourceKind.isStream
        if sceneFile?.mappings?.contains(where: { $0.source == source && $0.target == target }) == true {
            info = "Already mapped: \(label)"; return
        }
        edit("Mapped \(label)") { file in
            var list = file.mappings ?? []
            if stream { list.removeAll { $0.target == target } }
            list.append(targetKind == .value ? MappingSpec(source: source, target: target, amount: 0.25) : MappingSpec(source: source, target: target))
            file.mappings = list
        }
        selectedTarget = target
    }

    /// Points a mapping at another input of the same kind, keeping its settings (amount, invert,
    /// smooth, curve). A stream input takes one stream, so one already there is replaced.
    func retargetMapping(_ m: MappingRuntime, to target: String) {
        guard target != m.target else { return }
        guard kind(of: target) == m.kind else {
            info = "\(targetLabel(target)) takes \(kind(of: target).noun), not \(m.kind.noun)"; return
        }
        if sceneFile?.mappings?.contains(where: { $0.source == m.source && $0.target == target }) == true {
            info = "Already mapped: \(sourceLabel(m.source)) → \(targetLabel(target))"; return
        }
        edit("Remapped \(sourceLabel(m.source)) → \(targetLabel(target))") { file in
            var list = file.mappings ?? []
            if m.kind.isStream { list.removeAll { $0.target == target } }
            guard let i = list.firstIndex(where: { $0.source == m.source && $0.target == m.target }) else { return }
            list[i].target = target
            file.mappings = list
        }
        selectedTarget = target
    }

    func removeMapping(_ m: MappingRuntime) {
        edit("Removed mapping") { $0.mappings?.removeAll { $0.source == m.source && $0.target == m.target } }
    }

    func removeMappings(target: String) {
        edit("Removed mappings") { $0.mappings?.removeAll { $0.target == target } }
    }

    func mappings(for target: String) -> [MappingRuntime] {
        current?.mappings.filter { $0.target == target } ?? []
    }

    /// Waits for a click on a knob (or input of its kind) to move a mapping there. Again to cancel.
    func startRemap(_ m: MappingRuntime) {
        if remapping?.source == m.source && remapping?.target == m.target { mapSource = nil; return }
        mapSource = m.source
        remapping = m
    }

    /// Routes the output waiting to be mapped to a target: moves the mapping being remapped, or
    /// adds a new one. Remapping ends after one target; `keepMapping` keeps adding.
    func mapWaiting(to target: String, keepMapping: Bool = false) {
        guard let source = mapSource else { return }
        if let m = remapping {
            retargetMapping(m, to: target)
            mapSource = nil
            return
        }
        addMapping(source: source, target: target)
        if !keepMapping || kind(of: source).isStream { mapSource = nil }
    }

    /// Clicked a knob: routes the output waiting to be mapped, if any, or selects the knob.
    /// Returns true if the click was used for mapping.
    func knobClicked(_ target: String, keepMapping: Bool) -> Bool {
        if let source = mapSource, kind(of: source) == .value {
            mapWaiting(to: target, keepMapping: keepMapping)
            return true
        }
        selectedTarget = target
        selectDevice(devicePath(target))
        return false
    }

    /// "Low Poly · explode", "glow2 · amount", "Low Poly · Background".
    func targetLabel(_ target: String) -> String {
        if let v = current?.streamInputs.first(where: { $0.key == target }) { return "\(deviceName(v.deviceKey)) · \(v.label)" }
        if let t = current?.triggerInputs.first(where: { $0.key == target }) { return "\(deviceName(t.deviceKey)) · \(t.label)" }
        let parts = target.split(separator: ".").map(String.init)
        guard let name = parts.last else { return target }
        let device: String
        switch parts.first {
        case "generator": device = current?.generatorLabel ?? "Generator"
        case "camera": device = "Camera"
        case "lens": device = "Lens"
        case "audio": device = "Audio In"
        case "clock": device = "Clock"
        case "post", "mod": device = parts.count > 2 ? parts[1] : target
        default: device = parts.dropLast().joined(separator: ".")
        }
        return "\(device) · \(knobLabel(name))"
    }

    static let mappingsPasteboardType = NSPasteboard.PasteboardType("com.jimviz.mappings")
    /// The general pasteboard; the self-check swaps in a private one.
    @ObservationIgnored var pasteboard = NSPasteboard.general

    /// Copies mappings (all of the scene's when nil) as JSON, to paste into another scene.
    func copyMappings(_ list: [MappingRuntime]? = nil) {
        guard let scene = current else { return }
        let specs = (list ?? scene.mappings).map(\.spec)
        guard !specs.isEmpty, let data = try? JSONEncoder.pretty.encode(specs) else { return }
        let pb = pasteboard
        pb.clearContents()
        pb.setData(data, forType: Self.mappingsPasteboardType)
        pb.setString(String(decoding: data, as: UTF8.self), forType: .string)
        info = "Copied \(specs.count) mapping\(specs.count == 1 ? "" : "s")"
    }

    /// Pastes copied mappings into this scene, skipping ones it already has. Ones aimed at
    /// devices this scene lacks are kept but wait until a matching device is added.
    func pasteMappings() {
        let pb = pasteboard
        guard let data = pb.data(forType: Self.mappingsPasteboardType) ?? pb.string(forType: .string).map({ Data($0.utf8) }),
              let specs = try? JSONDecoder().decode([MappingSpec].self, from: data), !specs.isEmpty else {
            info = "Nothing to paste: copy mappings first"; return
        }
        var added = 0
        edit("Pasted mappings") { file in
            var list = file.mappings ?? []
            for spec in specs where !list.contains(where: { $0.source == spec.source && $0.target == spec.target }) {
                list.append(spec); added += 1
            }
            file.mappings = list
        }
        info = "Pasted \(added) mapping\(added == 1 ? "" : "s") (unsaved, ⌘S to save)"
    }

    var canPasteMappings: Bool {
        pasteboard.availableType(from: [Self.mappingsPasteboardType]) != nil
    }

    // MARK: Duplicate

    /// Writes a copy of a scene next to it and switches to it. For the current scene the copy
    /// includes unsaved edits; the original file is left as it is.
    func duplicateScene(_ url: URL) {
        var file: SceneFile
        if url == currentURL, var f = sceneFile, let scene = current {
            syncValues(from: scene, into: &f)
            file = f
        } else {
            guard let f = try? SceneFile.load(url) else { errors["duplicate"] = "could not read \(url.lastPathComponent)"; return }
            file = f
        }
        let taken = Set(sceneURLs.map { $0.deletingPathExtension().lastPathComponent })
        var name = "\(file.name) Copy", n = 2
        while taken.contains(slugify(name)) { name = "\(file.name) Copy \(n)"; n += 1 }
        file.name = name
        let dest = store.scenesDir.appendingPathComponent("\(slugify(name)).json")
        do {
            try file.write(to: dest)
            store.markSeen(dest)
            errors["duplicate"] = nil
            refreshSceneList()
            load(dest, animated: false)
            info = "Duplicated as \(name)"
        } catch {
            errors["duplicate"] = error.localizedDescription
        }
    }

    func reloadAll() {
        cache.removeAll()
        refreshSceneList()
        if let url = currentURL { rebuildKeepingValues(url) }
    }

    private func install(_ scene: RenderScene) {
        sceneLock.lock(); renderScene = scene; sceneLock.unlock()
        current = scene
        if let key = selectedDevice, !scene.deviceKeys.contains(key) { selectedDevice = nil }
        activateHardware()
    }

    /// Runs only the hardware the scenes on screen (both, mid-transition) use: the audio
    /// sources their Audio Ins listen to, MIDI while one has a MIDI Input, and the cameras their webcams
    /// use, with depth estimation for those whose Depth is mapped. Everything else stops.
    private func activateHardware() {
        let scenes = [current, pendingScene?.scene].compactMap { $0 }
        let sources = scenes.flatMap(\.videoSources)
        let depthFeeds = Set(sources.filter(\.depthMapped).map { ObjectIdentifier($0.sourceFeed) })
        let feeds: [any VideoSourceFeed] = webcams.allFeeds + videos.allFeeds + pictures.allFeeds
        for f in feeds { f.depthWanted = depthFeeds.contains(ObjectIdentifier(f)) }
        webcams.activate(scenes.flatMap(\.webcams).map(\.feed))
        videos.activate(scenes.flatMap(\.videos).map(\.feed))
        pictures.activate(scenes.flatMap(\.pictures).map(\.feed))

        guard hardwareReady else { return }
        audioCaptures.activate(scenes.compactMap { $0.audioIn?.capture })
        midi.setActive(scenes.contains { !$0.midiInputs.isEmpty })
    }

    /// The source a new Audio In listens to.
    static let defaultAudioSource = AudioCapture.Source.systemAudio

    /// Points Audio In at a source, on its first channel pair.
    func setAudioSource(_ source: AudioCapture.Source) {
        edit("Audio In: \(audioCaptures.label(source))") { file in
            guard let i = file.inputs.firstIndex(where: { $0.type == "audio" }) else { return }
            file.inputs[i].device = source.key
            file.inputs[i].channelPair = nil
        }
    }

    /// Points Audio In at another stereo pair of its source (0 is channels 1–2).
    func setAudioChannelPair(_ pair: Int) {
        edit("Audio In: channels \(pair * 2 + 1)–\(pair * 2 + 2)") { file in
            guard let i = file.inputs.firstIndex(where: { $0.type == "audio" }) else { return }
            file.inputs[i].channelPair = pair == 0 ? nil : pair
        }
    }

    /// Points a webcam at a camera by name, or at the default camera (nil).
    func setWebcamDevice(_ key: String, _ device: String?) {
        edit("Webcam: \(device ?? "Default camera")") { file in
            guard let i = file.inputs.firstIndex(where: { $0.deviceKey == key }) else { return }
            file.inputs[i].device = device
        }
    }

    /// Points a Video or Picture input at a media file.
    func setMediaFile(_ key: String, _ path: String?) {
        let name = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None"
        edit("\(deviceName(key)): \(name)") { file in
            guard let i = file.inputs.firstIndex(where: { $0.deviceKey == key }) else { return }
            file.inputs[i].file = path
        }
    }

    /// Connects a stream output to a stream input, or disconnects the input (nil).
    func setStreamInput(_ target: String, _ source: String?) {
        guard let source else {
            edit("Disconnected \(targetLabel(target))") { $0.mappings?.removeAll { $0.target == target } }
            return
        }
        addMapping(source: source, target: target)
    }

    /// The kind of IO a key is: a stream output or input's kind, a trigger (trigger inputs and
    /// outputs), or a value (other outputs and knobs).
    func kind(of key: String) -> IOKind {
        if let scene = current {
            if let o = scene.streamOutputs.first(where: { $0.key == key }) { return o.kind }
            if let i = scene.streamInputs.first(where: { $0.key == key }) { return i.kind }
            if scene.triggerInputs.contains(where: { $0.key == key }) { return .trigger }
            if let o = scene.outputs.first(where: { $0.key == key }) { return o.kind }
        }
        return StreamOutput.kind(ofKey: key) ?? (TriggerInput.isKey(key) ? .trigger : .value)
    }

    /// "Webcam · Video", "Audio In · Kick".
    func sourceLabel(_ key: String) -> String {
        if let v = current?.streamOutputs.first(where: { $0.key == key }) { return "\(v.device) · \(v.name)" }
        return Outputs.label(key, in: current?.outputs ?? [])
    }

    /// "Audio In", "lfo2", "Low Poly", "glow".
    func deviceName(_ key: String) -> String {
        switch key {
        case "audio": return "Audio In"
        case "clock": return "Clock"
        case "camera": return "Camera"
        case "lens": return current?.lens?.label ?? "Lens"
        case "palette": return "Palette"
        case _ where key.hasPrefix("palette."):
            return current?.palettes.first { $0.key == key }?.title ?? "Palette"
        case "generator": return current?.generatorLabel ?? "Generator"
        case _ where key.hasPrefix("generator."):
            return current?.generators.first { $0.key == key }?.label ?? "Generator"
        case _ where key.hasPrefix("webcam."):
            return current?.webcams.first { $0.key == key }.map { "Webcam · \($0.device ?? "Default camera")" } ?? "Webcam"
        case _ where key.hasPrefix("video."):
            return current?.videos.first { $0.key == key }.map { "Video · \($0.displayName)" } ?? "Video"
        case _ where key.hasPrefix("picture."):
            return current?.pictures.first { $0.key == key }.map { "Picture · \($0.displayName)" } ?? "Picture"
        case _ where key.hasPrefix("midi."):
            return current?.midiInputs.first { $0.key == key }.map { "MIDI Input · \($0.title)" } ?? "MIDI Input"
        default: return key.split(separator: ".").dropFirst().joined(separator: ".")
        }
    }

    // MARK: Building

    func build(_ file: SceneFile, reuse: RenderScene?) -> RenderScene? {
        // Generators, from the scene's copy of their tool and preset values.
        var generators: [GeneratorRuntime] = []
        errors["generator"] = nil
        for slot in file.generators {
            let slotKey = slot.key
            let slotId = slot.id ?? "generator"
            guard case let .generator(shader, meshPipe, blendPipe, bgPipe)? = compiled(store.generatorShader(slot.type), as: .generator) else {
                return nil
            }
            guard let mesh = shader.mesh else {
                errors["generator"] = "\(slot.type).metal has no // @mesh line"
                return nil
            }
            if mesh == .globe {
                do { try WorldMap.load(store.mapsDir.appendingPathComponent("world.json")) } catch {
                    errors["generator"] = "Maps/world.json invalid: \(error.localizedDescription)"
                    return nil
                }
            }
            let old = reuse?.generators.first { $0.key == slotKey }
            let same = old?.type == slot.type && old?.preset == slot.preset
            let bank = ParamBank(defs: shader.params, values: slot.params ?? [:], reuse: same ? old?.bank : nil)
            let label = presetName(.generator, slot.type, slot.preset) ?? Tools.label(.generator, slot.type)
            generators.append(GeneratorRuntime(id: slotId, key: slotKey, type: slot.type, preset: slot.preset, label: label,
                                               mesh: mesh, bank: bank, meshPipeline: meshPipe, blendPipeline: blendPipe, backgroundPipeline: bgPipe,
                                               inputs: shader.inputs, device: renderer.device,
                                               reusing: old?.type == slot.type ? old : nil))
        }

        // Camera.
        let camera: ParamBank?
        let cameraMotion: CameraMotion?
        let cameraPreset: String?
        let cameraLabel: String?
        if let camSlot = file.camera {
            guard let rig = CameraRig(rawValue: camSlot.type) else {
                errors["camera"] = "unknown camera type \(camSlot.type)"
                return nil
            }
            errors["camera"] = nil
            let same = reuse?.cameraMotion?.rig == rig
            camera = ParamBank(defs: rig.defs, values: camSlot.params ?? [:], reuse: same ? reuse?.camera : nil)
            cameraMotion = same ? reuse?.cameraMotion : CameraMotion(rig, continuing: current?.cameraMotion)
            cameraPreset = camSlot.preset
            cameraLabel = presetName(.camera, camSlot.type, camSlot.preset) ?? Tools.label(.camera, camSlot.type)
        } else {
            errors["camera"] = nil
            camera = nil
            cameraMotion = nil
            cameraPreset = nil
            cameraLabel = nil
        }

        // The camera effect: a lens, drawing an ST map. While its shader fails to compile the
        // lens keeps the knobs and pipeline it had.
        var lens: LensRuntime?
        errors["lens"] = nil
        if let slot = file.lens {
            guard store.availableLenses().contains(slot.type) else {
                errors["lens"] = "unknown lens type \(slot.type)"
                return nil
            }
            let old = reuse?.lens?.type == slot.type ? reuse?.lens : nil
            var defs: [ParamDef] = [], pipeline: MTLRenderPipelineState?
            if case let .lens(shader, p)? = compiled(store.lensShader(slot.type), as: .lens) { defs = shader.params; pipeline = p }
            else if let old { defs = old.bank.params.map(\.def); pipeline = old.pipeline }
            let bank = ParamBank(defs: defs, values: slot.params ?? [:], reuse: old?.preset == slot.preset ? old?.bank : nil)
            lens = LensRuntime(type: slot.type, preset: slot.preset,
                               label: presetName(.lens, slot.type, slot.preset) ?? Tools.label(.lens, slot.type),
                               bank: bank, pipeline: pipeline, stmap: reuse?.lens?.stmap ?? renderer.makeSTMapTexture())
        }

        // Modulation: LFOs, Maths and Macros.
        var modulators: [ModulatorRuntime] = []
        errors["modulator"] = nil
        for spec in file.modulators where !modulators.contains(where: { $0.id == spec.id }) {
            guard let type = ModulatorType(rawValue: spec.type) else {
                errors["modulator"] = "unknown modulator type \(spec.type)"
                return nil
            }
            let old = reuse?.modulators.first { $0.id == spec.id && $0.type == type }
            let bank = ParamBank(defs: type.defs, values: spec.params ?? [:], reuse: old?.bank)
            let mod = ModulatorRuntime(id: spec.id, type: type, presetLabel: presetName(.modulation, spec.type, spec.preset),
                                       enabled: spec.enabled ?? true, bank: bank)
            if let old { mod.continuePhase(from: old) }
            modulators.append(mod)
        }

        // Effects, in chain order.
        var effects: [EffectRuntime] = []
        var usedIDs = Set<String>()
        for fx in file.effects {
            var id = fx.id ?? fx.effect
            var n = 2
            while usedIDs.contains(id) { id = "\(fx.id ?? fx.effect)\(n)"; n += 1 }
            usedIDs.insert(id)
            let old = reuse?.effects.first { $0.id == id && $0.effect == fx.effect }
            var defs: [ParamDef] = []
            var pipeline: MTLRenderPipelineState?
            var selfHistory = false
            var fxInputs: [StreamInputDef] = []
            if case let .effect(shader, p)? = compiled(store.effectShader(fx.effect), as: .effect) {
                defs = shader.params; pipeline = p; selfHistory = shader.selfHistory; fxInputs = shader.inputs
            } else if let old {
                defs = old.bank.params.map(\.def); pipeline = old.pipeline; selfHistory = old.selfHistory
                fxInputs = old.inputs
            }
            let bank = ParamBank(defs: defs, values: fx.params ?? [:], reuse: old?.bank)
            let history = selfHistory ? (old?.history ?? renderer.makeHistoryPair()) : nil
            let runtime = EffectRuntime(id: id, effect: fx.effect, presetLabel: presetName(.effect, fx.effect, fx.preset),
                                        enabled: fx.enabled ?? true, bank: bank, pipeline: pipeline, selfHistory: selfHistory,
                                        inputs: fxInputs, history: history)
            effects.append(runtime)
        }

        // Palettes, in chain order. The first is `palette`, the rest `palette.<id>`.
        var palettes: [PaletteModel] = []
        for slot in file.palettes where !palettes.contains(where: { $0.key == slot.key }) {
            let old = reuse?.palettes.first { $0.key == slot.key }
            let colors = slot.colors.compactMap(parseHexColor)
            let bank = ParamBank(defs: PaletteParams.defs, values: slot.params ?? [:], reuse: old?.bank)
            palettes.append(PaletteModel(key: slot.key, title: Self.paletteTitle(slot.id), preset: slot.preset,
                                         label: presetName(.palette, "palette", slot.preset) ?? "Custom",
                                         colors.count >= 2 ? colors : Tools.defaultPalette.compactMap(parseHexColor),
                                         bank: bank, gpu: old?.gpu ?? renderer.makePaletteTextures()))
        }

        // Inputs: one Audio In and one Clock at most, any number of MIDI inputs and webcams.
        // Rebuilding a scene carries each on; a different scene's pick up where the current
        // scene's are, so levels and the beat continue across a switch.
        var inputs: [InputDevice] = []
        var outputs: [OutputSignal] = []
        errors["input"] = nil
        for spec in file.inputs {
            switch spec.type {
            case "audio" where !inputs.contains { $0.id == "audio" }:
                guard let key = spec.device, let source = AudioCapture.Source(key: key) else {
                    errors["input"] = "Audio In needs a device: rekordbox, system or input:<uid> (got \(spec.device ?? "none"))"
                    return nil
                }
                let old = reuse?.audioIn
                let capture = audioCaptures.capture(source, channelPair: spec.channelPair ?? 0)
                let a = AudioInRuntime(capture: capture, params: spec.params ?? [:],
                                       makeSpectrum: renderer.makeSpectrumTextures,
                                       reuse: old, continuing: reuse == nil ? current?.audioIn : nil)
                inputs.append(.audio(a)); outputs += a.outputs
            case "clock" where !inputs.contains { $0.id == "clock" }:
                let c = ClockRuntime(params: spec.params ?? [:], reuse: reuse?.clock,
                                     continuing: reuse == nil ? current?.clock : nil)
                inputs.append(.clock(c)); outputs += c.outputs
            case "midi":
                let id = spec.id ?? "midi"
                guard !inputs.contains(where: { $0.id == "midi.\(id)" }) else { continue }
                let old = reuse?.midiInputs.first { $0.id == id }
                let m = MIDIInputRuntime(id: id, device: spec.device, controls: (spec.controls ?? []).compactMap(MIDIControl.init(key:)),
                                         reuse: old)
                inputs.append(.midi(m)); outputs += m.outputs
            case "webcam":
                let id = spec.id ?? "webcam"
                guard !inputs.contains(where: { $0.id == "webcam.\(id)" }) else { continue }
                let old = reuse?.webcams.first { $0.id == id }
                let (defs, gpu) = videoSourceGPU(reuse: old)
                let w = WebcamRuntime(id: id, device: spec.device, bank: ParamBank(defs: defs, values: spec.params ?? [:], reuse: old?.bank),
                                      feed: webcams.feed(named: spec.device), gpu: gpu)
                inputs.append(.webcam(w)); outputs += w.outputs
            case "video":
                let id = spec.id ?? "video"
                guard !inputs.contains(where: { $0.id == "video.\(id)" }) else { continue }
                let old = reuse?.videos.first { $0.id == id }
                let (defs, gpu) = videoSourceGPU(reuse: old)
                let bank = ParamBank(defs: defs, unpacked: VideoTransport.defs, values: spec.params ?? [:], reuse: old?.bank)
                let v = VideoRuntime(id: id, file: spec.file, bank: bank, feed: videos.feed(for: spec.file, store: store), gpu: gpu)
                inputs.append(.video(v)); outputs += v.outputs
            case "picture":
                let id = spec.id ?? "picture"
                guard !inputs.contains(where: { $0.id == "picture.\(id)" }) else { continue }
                let old = reuse?.pictures.first { $0.id == id }
                let (defs, gpu) = videoSourceGPU(reuse: old)
                let p = PictureRuntime(id: id, file: spec.file, bank: ParamBank(defs: defs, values: spec.params ?? [:], reuse: old?.bank),
                                       feed: pictures.feed(for: spec.file, store: store), gpu: gpu)
                inputs.append(.picture(p)); outputs += p.outputs
            case "audio", "clock":
                continue
            default:
                errors["input"] = "unknown input \(spec.type)"
            }
        }
        if let cameraMotion {
            outputs += cameraMotion.outputs
        }
        outputs += modulators.flatMap(\.outputs)

        // Mappings. Ones whose source or target device isn't in the scene wait, inactive,
        // until it is, so removing and re-adding a device keeps its mappings.
        var banks: [String: ParamBank] = [:]
        for input in inputs {
            switch input {
            case .audio(let a): banks["audio"] = a.bank
            case .clock(let c): banks["clock"] = c.bank
            case .webcam(let w): banks[w.key] = w.bank
            case .video(let v): banks[v.key] = v.bank
            case .picture(let p): banks[p.key] = p.bank
            case .midi: break
            }
        }
        if let camera { banks["camera"] = camera }
        if let lens { banks[LensRuntime.key] = lens.bank }
        for pal in palettes { banks[pal.key] = pal.bank }
        for gen in generators { banks[gen.key] = gen.bank }
        if let first = generators.first, banks["generator"] == nil { banks["generator"] = first.bank }
        for fx in effects { banks["post.\(fx.id)"] = fx.bank }
        for m in modulators { banks["mod.\(m.id)"] = m.bank }
        for bank in banks.values {
            for p in bank.params { p.isModulated = false; p.display = p.base }
        }
        let outputsByKey = Dictionary(outputs.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let generatorLabel = generators.first?.label
        var mappings: [MappingRuntime] = []
        // Stream outputs (Audio In's spectrum, webcam videos, palettes), in chain order, and
        // the stream inputs shaders declare.
        var streamOutputs: [StreamOutput] = []
        for input in inputs {
            switch input {
            case .audio(let a): streamOutputs += a.streamOutputs
            case .clock(let c): streamOutputs.append(c.syncOutput)
            case .webcam(let w): streamOutputs += [w.video, w.depthVideo]
            case .video(let v): streamOutputs += [v.video, v.depthVideo]
            case .picture(let p): streamOutputs += [p.video, p.depthVideo]
            case .midi: break
            }
        }
        if let lens { streamOutputs.append(lens.output) }
        for pal in palettes {
            let gpu = pal.gpu
            streamOutputs.append(StreamOutput(pal.outputKey, "Colours", device: pal.title, kind: .palette) { gpu.current })
        }
        let streamsByKey = Dictionary(streamOutputs.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var streamInputs: [String: (label: String, kind: IOKind)] = [:]
        if inputs.contains(where: { $0.id == "clock" }) { streamInputs[StreamInput.clockAudioKey] = ("Clock · Audio", .audio) }
        for mod in modulators where mod.type == .lfo { streamInputs["mod.\(mod.id).sync"] = ("\(mod.id) · Sync", .clock) }
        if camera != nil { streamInputs[StreamInput.cameraLensKey] = ("Camera · Lens", .stmap) }
        for gen in generators {
            for v in gen.inputs {
                streamInputs["\(gen.key).\(v.name)"] = ("\(gen.label ?? "Generator") · \(v.label)", v.kind)
                if gen.key != "generator" && gen === generators.first {
                    streamInputs["generator.\(v.name)"] = ("\(gen.label ?? "Generator") · \(v.label)", v.kind)
                }
            }
        }
        for fx in effects { for v in fx.inputs { streamInputs["post.\(fx.id).\(v.name)"] = ("\(fx.id) · \(v.label)", v.kind) } }
        var streamBindings: [String: StreamOutput] = [:]
        // Trigger inputs, with their labels for mappings.
        var triggers: [String: (input: TriggerInput, label: String)] = [:]
        for t in cameraMotion?.triggerInputs ?? [] { triggers[t.key] = (t, "Camera · \(t.label)") }
        for case .clock(let c) in inputs { triggers[c.firstBeatTrigger.key] = (c.firstBeatTrigger, "Clock · \(c.firstBeatTrigger.label)") }
        for case .video(let v) in inputs { triggers[v.jumpTrigger.key] = (v.jumpTrigger, "\(v.displayName) · \(v.jumpTrigger.label)") }
        for mod in modulators { if let t = mod.resetTrigger { triggers[t.key] = (t, "\(mod.id) · \(t.label)") } }

        /// Why a source isn't available, when its device isn't in the chain.
        func missing(_ source: String) -> String {
            let device = devicePath(source)
            if source.hasPrefix("audio.") { return "Needs Audio In in the chain" }
            if source.hasPrefix("clock.") { return "Needs Clock in the chain" }
            if source.hasPrefix("camera.") { return "Needs Camera in the chain" }
            if source == StreamOutput.paletteKey { return "Needs a Palette in the chain" }
            if source.hasPrefix("palette.") { return "Needs its Palette in the chain" }
            if source.hasPrefix("lens.") { return "Needs a Lens in the chain" }
            if source.hasPrefix("mod.") { return "\(device.dropFirst(4)) isn't in this scene" }
            if source.hasPrefix("webcam.") { return "Needs its Webcam in the chain" }
            if source.hasPrefix("video.") { return "Needs its Video in the chain" }
            if source.hasPrefix("picture.") { return "Needs its Picture in the chain" }
            if source.hasPrefix("midi.") {
                return inputs.contains { $0.id == device } ? "The MIDI input hasn't learned this control"
                                                           : "Needs its MIDI Input in the chain"
            }
            return "Unknown source \(source)"
        }

        errors["mapping"] = nil
        for (i, spec) in (file.mappings ?? []).enumerated() {
            // Streams: a stream output into a stream input of the same kind.
            if let kind = streamsByKey[spec.source]?.kind ?? StreamOutput.kind(ofKey: spec.source) {
                let stream = streamsByKey[spec.source]
                let input = streamInputs[spec.target]
                var problem: String?
                if stream == nil { problem = missing(spec.source) }
                else if let input {
                    if input.kind != kind { problem = "\(input.label) takes \(input.kind.noun), not \(kind.noun)" }
                    else if streamBindings[spec.target] != nil { problem = "Another \(kind.noun) is already mapped here" }
                } else {
                    problem = banks[devicePath(spec.target)]?[spec.target.split(separator: ".").last.map(String.init) ?? ""] != nil
                        ? "Knobs take values, not \(kind.noun)" : "\(targetLabel(spec.target)) isn't in this scene"
                }
                if problem == nil, let stream { streamBindings[spec.target] = stream }
                let fallbackLabel: String
                switch kind {
                case .spectrum: fallbackLabel = "Audio In · \(StreamOutput.spectrumNames[spec.source] ?? "Spectrum")"
                case .palette: fallbackLabel = "Palette · Colours"
                case .audio: fallbackLabel = "Audio In · Audio Out"
                case .clock: fallbackLabel = "Clock · Sync"
                case .stmap: fallbackLabel = "Lens · ST Map"
                default: fallbackLabel = spec.source.hasSuffix(".depth") ? "Webcam · Depth" : "Webcam · Video"
                }
                mappings.append(MappingRuntime(
                    id: "\(i):\(spec.source)>\(spec.target)", spec: spec, kind: kind, output: nil,
                    stream: problem == nil ? stream : nil, param: nil,
                    sourceLabel: stream.map { "\($0.device) · \($0.name)" } ?? fallbackLabel,
                    targetLabel: input?.label ?? targetLabel(spec.target), problem: problem))
                continue
            }
            if let amount = spec.amount, !(0...1).contains(amount) {
                errors["mapping"] = "mapping \(spec.source) → \(spec.target): amount \(amount) is outside 0...1 (use invert)"
                return nil
            }
            let output = outputsByKey[spec.source]
            // Triggers: a trigger or value output into a trigger input.
            let trigger = triggers[spec.target]
            if trigger != nil || TriggerInput.isKey(spec.target) || output?.kind == .trigger {
                var problem: String?
                if output == nil { problem = missing(spec.source) }
                else if trigger == nil {
                    problem = TriggerInput.isKey(spec.target) ? "\(targetLabel(spec.target)) isn't in this scene"
                                                              : "Knobs take values, not triggers"
                }
                mappings.append(MappingRuntime(
                    id: "\(i):\(spec.source)>\(spec.target)", spec: spec, kind: .trigger, output: problem == nil ? output : nil,
                    param: nil, trigger: problem == nil ? trigger?.input : nil,
                    sourceLabel: Outputs.label(spec.source, in: outputs),
                    targetLabel: trigger?.label ?? targetLabel(spec.target), problem: problem))
                continue
            }
            var problem: String?
            if let input = streamInputs[spec.target] { problem = "\(input.label) takes \(input.kind.noun), not values" }
            if output == nil { problem = missing(spec.source) }
            let parts = spec.target.split(separator: ".").map(String.init)
            var param: Param?
            if let name = parts.last, parts.count >= 2 {
                let path = parts.dropLast().joined(separator: ".")
                if let bank = banks[path] {
                    param = bank[name]
                    if param == nil { problem = problem ?? "No knob named \(name)" }
                } else {
                    problem = problem ?? "\(path.hasPrefix("generator") ? "Generator" : parts.count > 2 ? parts[1] : path) isn't in this scene"
                }
            } else {
                problem = problem ?? "Bad target \(spec.target)"
            }
            if problem == nil { param?.isModulated = true }
            let device: String
            switch parts.first {
            case "generator": device = generatorLabel ?? "Generator"
            case "camera": device = "Camera"
            case "palette": device = Self.paletteTitle(parts.count > 2 ? parts[1] : nil)
            case "lens": device = "Lens"
            case "audio": device = "Audio In"
            case "clock": device = "Clock"
            default: device = parts.count > 2 ? parts[1] : (parts.first ?? spec.target)
            }
            mappings.append(MappingRuntime(
                id: "\(i):\(spec.source)>\(spec.target)", spec: spec, output: problem == nil ? output : nil,
                param: problem == nil ? param : nil,
                sourceLabel: Outputs.label(spec.source, in: outputs),
                targetLabel: "\(device) · \(knobLabel(parts.last ?? spec.target))", problem: problem))
        }

        // The Clock hears Audio In, and LFOs follow the Clock, only through their mappings.
        let clock = inputs.lazy.compactMap { if case .clock(let c) = $0 { return c } else { return nil } }.first
        let audioIn = inputs.lazy.compactMap { if case .audio(let a) = $0 { return a } else { return nil } }.first
        clock?.listen(to: streamBindings[StreamInput.clockAudioKey] != nil ? audioIn : nil)
        for mod in modulators {
            mod.sync(to: streamBindings["mod.\(mod.id).sync"] != nil ? clock : nil)
        }
        // A shader's rate knobs follow the Clock only while Sync is mapped into its clock input.
        func synced(_ prefix: String, _ inputs: [StreamInputDef]) -> ClockRuntime? {
            inputs.contains { $0.kind == .clock && streamBindings["\(prefix).\($0.name)"] != nil } ? clock : nil
        }
        for gen in generators { gen.bank.syncClock = synced(gen.key, gen.inputs) }
        for fx in effects { fx.bank.syncClock = synced("post.\(fx.id)", fx.inputs) }

        let scene = RenderScene(name: file.name, generators: generators, inputs: inputs, modulators: modulators,
                                streamOutputs: streamOutputs, streamBindings: streamBindings,
                                camera: camera, cameraMotion: cameraMotion, cameraPreset: cameraPreset, cameraLabel: cameraLabel,
                                lens: lens, effects: effects, palettes: palettes, outputs: outputs, mappings: mappings,
                                banksByPath: banks)
        // The depth model runs only for video sources whose Depth goes somewhere.
        let boundVideo = Set(streamBindings.values.map(\.key))
        for source in scene.videoSources { source.depthMapped = boundVideo.contains(source.depthVideo.key) }
        return scene
    }

    /// The webcam processing shader's knobs and pipelines for a video source, with its textures
    /// carried over from the runtime it replaces. While the shader fails to compile, the old
    /// runtime's knobs and pipelines stay.
    private func videoSourceGPU(reuse old: VideoSourceRuntime?) -> (defs: [ParamDef], gpu: VideoSourceGPU) {
        var defs: [ParamDef] = [], pipeline: MTLRenderPipelineState?, depthPipeline: MTLRenderPipelineState?
        if case let .webcam(shader, p, d)? = compiledWebcam() { defs = shader.params; pipeline = p; depthPipeline = d }
        else if let old { defs = old.bank.packedDefs; pipeline = old.pipeline; depthPipeline = old.depthPipeline }
        let textures = old.map { ($0.processed, $0.depth, $0.depthHistory) } ?? renderer.makeVideoSourceTextures()
        return (defs, VideoSourceGPU(pipeline: pipeline, depthPipeline: depthPipeline,
                                     processed: textures.0, depth: textures.1, depthHistory: textures.2))
    }

    /// Compiles the webcam processing shader, or returns the cached result.
    private func compiledWebcam() -> CacheEntry? {
        let url = store.webcamShader
        let key = url.standardizedFileURL
        if let hit = cache[key] { return hit }
        do {
            let shader = try compiler.compile(url)
            let entry = CacheEntry.webcam(shader, try renderer.makeFullscreenPipeline(shader, fragment: "webcam"),
                                          depth: try renderer.makeFullscreenPipeline(shader, fragment: "webcam_depth"))
            cache[key] = entry
            errors[url.lastPathComponent] = nil
            return entry
        } catch {
            errors[url.lastPathComponent] = describe(error)
            return nil
        }
    }

    private enum ShaderRole { case generator, effect, lens }

    /// Compiles a shader, or returns the cached result. Records errors per file.
    private func compiled(_ url: URL, as role: ShaderRole) -> CacheEntry? {
        let key = url.standardizedFileURL
        if let hit = cache[key] { return hit }
        do {
            let shader = try compiler.compile(url)
            let entry: CacheEntry
            switch role {
            case .generator:
                let p = try renderer.makeGeneratorPipelines(shader)
                entry = .generator(shader, mesh: p.mesh, blend: p.blend, background: p.background)
            case .effect:
                entry = .effect(shader, try renderer.makeFullscreenPipeline(shader, fragment: "effect"))
            case .lens:
                entry = .lens(shader, try renderer.makeFullscreenPipeline(shader, fragment: "lens", pixelFormat: LensRuntime.format))
            }
            cache[key] = entry
            errors[url.lastPathComponent] = nil
            return entry
        } catch {
            errors[url.lastPathComponent] = describe(error)
            return nil
        }
    }

    /// Copies live knob values, effect on/off state and palette edits back into the file.
    private func syncValues(from scene: RenderScene, into file: inout SceneFile) {
        for (i, gen) in zip(file.generators.indices, scene.generators) { file.generators[i].params = gen.bank.baseValues }
        if let cam = scene.camera {
            file.camera?.params = cam.baseValues
        }
        if let lens = scene.lens { file.lens?.params = lens.bank.baseValues }
        for i in file.modulators.indices {
            guard let m = scene.modulators.first(where: { $0.id == file.modulators[i].id }) else { continue }
            file.modulators[i].params = m.bank.baseValues
            file.modulators[i].enabled = m.enabled ? nil : false
        }
        for i in file.inputs.indices {
            switch file.inputs[i].type {
            case "audio": if let a = scene.audioIn { file.inputs[i].params = a.bank.baseValues }
            case "clock": if let c = scene.clock { file.inputs[i].params = c.bank.baseValues }
            case "webcam":
                let id = file.inputs[i].id ?? "webcam"
                guard let w = scene.webcams.first(where: { $0.id == id }) else { continue }
                file.inputs[i].id = id
                file.inputs[i].params = w.bank.baseValues
            case "video":
                let id = file.inputs[i].id ?? "video"
                guard let v = scene.videos.first(where: { $0.id == id }) else { continue }
                file.inputs[i].id = id
                file.inputs[i].params = v.bank.baseValues
            case "picture":
                let id = file.inputs[i].id ?? "picture"
                guard let p = scene.pictures.first(where: { $0.id == id }) else { continue }
                file.inputs[i].id = id
                file.inputs[i].params = p.bank.baseValues
            default: break
            }
        }

        // Mappings are built one per spec, in order, so their edited settings map straight back.
        if scene.mappings.count == (file.mappings ?? []).count {
            file.mappings = scene.mappings.map(\.spec)
        }
        for i in file.effects.indices {
            let id = file.effects[i].id ?? file.effects[i].effect
            file.effects[i].id = id
            guard let fx = scene.effects.first(where: { $0.id == id }) else { continue }
            file.effects[i].params = fx.bank.baseValues
            file.effects[i].enabled = fx.enabled ? nil : false
        }
        for i in file.palettes.indices {
            guard let pal = scene.palettes.first(where: { $0.key == file.palettes[i].key }) else { continue }
            let colors = pal.colors.map(hexString)
            // Edited colors no longer match the preset they came from.
            if colors != file.palettes[i].colors { file.palettes[i].colors = colors; file.palettes[i].preset = nil }
            file.palettes[i].params = pal.bank.baseValues
        }
    }

    /// Rebuilds the current scene after a shader or preset change, keeping unsaved knob values.
    private func rebuildKeepingValues(_ url: URL) {
        guard var file = sceneFile, let scene = current else { load(url); return }
        syncValues(from: scene, into: &file)
        if let rebuilt = build(file, reuse: scene) {
            install(rebuilt)
            info = "Reloaded"
        }
    }

    // MARK: Hot reload

    private func filesChanged(_ urls: [URL]) {
        var rebuild = false
        var sceneChanged = false
        for url in urls {
            if url.pathExtension == "metal" {
                rebuild = true
                // Shared code (common.metal, `_` include files) recompiles everything.
                if url.lastPathComponent == "common.metal" || url.lastPathComponent.hasPrefix("_") { cache.removeAll() }
                // A new or removed generator changes the browser.
                if url.path.contains("/Shaders/generators/") || url.path.contains("/Shaders/lenses/") { refreshTools() }
                cache[url.standardizedFileURL] = nil
            } else if url.pathExtension == "json" {
                if url.standardizedFileURL == currentURL?.standardizedFileURL { sceneChanged = true }
                // Preset names show in device headers.
                if url.path.contains("/Presets/") { rebuild = true; refreshTools() }
            }
        }
        refreshSceneList()
        guard let url = currentURL else {
            if let first = sceneURLs.first { load(first) }
            return
        }
        if sceneChanged {
            load(url)
        } else if rebuild {
            rebuildKeepingValues(url)
        }
    }

    // MARK: UI refresh

    private func uiTick() {
        if let scene = current {
            for bank in scene.banks {
                for p in bank.params where p.isModulated {
                    if abs(p.display - p.live) > p.def.span * 0.002 { p.display = p.live }
                }
            }
        }
        current?.audioIn?.refreshMeters()
        current?.clock?.refresh()
        if let pending = pendingScene {
            if !loop.transition.isTransitioning {
                currentURL = pending.url
                sceneFile = pending.file
                install(pending.scene)
                pendingScene = nil
                info = "Switched to \(pending.file.name)"
            }
        }

        if abs(fps - loop.fps) > 0.5 { fps = loop.fps }
        if abs(gpuMs - loop.gpuMs) > 0.05 { gpuMs = loop.gpuMs }
    }

    /// MIDI arrives on main and goes to the scene's MIDI inputs. Each takes what is for it;
    /// a control new to one that is learning is added to the scene as that input's output.
    func handleMIDI(_ msg: MIDIMessage) {
        guard let scene = current else { return }
        for input in scene.midiInputs {
            if let (control, value) = input.handle(msg) { learn(control, into: input, value: value) }
        }
    }

    private func learn(_ control: MIDIControl, into input: MIDIInputRuntime, value: Float) {
        edit("Learned \(control.label)") { file in
            guard let i = file.inputs.firstIndex(where: { $0.deviceKey == input.key }) else { return }
            file.inputs[i].controls = (file.inputs[i].controls ?? []) + [control.key]
        }
        // The rebuilt input has the control now; give it the value that taught it.
        current?.midiInputs.first { $0.key == input.key }?.receive(control, value)
    }

    /// Points a MIDI input at a device by name, or at every device (nil).
    func setMIDIDevice(_ key: String, _ device: String?) {
        edit("MIDI Input: \(device ?? "All devices")") { file in
            guard let i = file.inputs.firstIndex(where: { $0.deviceKey == key }) else { return }
            file.inputs[i].device = device
        }
    }

    /// Forgets a learned control. Mappings from it stay, inactive, in case it's learned again.
    func forgetMIDIControl(_ outputKey: String) {
        let key = devicePath(outputKey), control = outputKey.split(separator: ".").last.map(String.init)
        edit("Forgot \(control.flatMap(MIDIControl.init(key:))?.label ?? outputKey)") { file in
            guard let i = file.inputs.firstIndex(where: { $0.deviceKey == key }) else { return }
            file.inputs[i].controls?.removeAll { $0 == control }
        }
    }

    private func describe(_ error: Error) -> String {
        if let e = error as? ShaderError { return e.message }
        if let e = error as? DecodingError {
            switch e {
            case .keyNotFound(let key, _): return "missing key \(key.stringValue)"
            case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
                let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
                return "\(path.isEmpty ? "" : path + ": ")\(ctx.debugDescription)"
            @unknown default: return "\(e)"
            }
        }
        return error.localizedDescription
    }
}
