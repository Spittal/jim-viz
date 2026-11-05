import SwiftUI

/// Ableton-style device browser. Tools are grouped by section (Inputs, Modulation, Cameras,
/// Colour, one per generator category such as Low Poly, Effects); the Generation filter shows
/// Cameras, Colour and the generator categories;
/// each tool expands to show its presets. Drag a tool or a preset onto the chain, double-click
/// it, or hover and click +. A tool on its own loads with default settings.
struct DeviceBrowser: View {
    @Environment(Engine.self) private var engine
    @State private var search = ""
    @State private var filter: Filter = .all
    /// Expanded tool ids, comma-separated, kept between launches.
    @AppStorage("browser.expanded") private var expandedRaw = "camera:orbit,palette:palette"

    enum Filter: String, CaseIterable {
        case all = "All", inputs = "Inputs", modulation = "Modulation", generation = "Generation", effects = "Effects"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tools and presets", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            .padding(.horizontal, 8).padding(.top, 8)

            Picker("", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if show(.inputs) { section("Inputs", [.input]) }
                    if show(.modulation) { section("Modulation", [.modulation]) }
                    if show(.generation) {
                        section("Cameras", [.camera])
                        // Colour sources: palettes now, later anything else that makes colours.
                        section("Colour", [.palette])
                        ForEach(generatorCategories, id: \.self) { category in
                            section(Tools.categoryLabel(category), [.generator], category: category)
                        }
                    }
                    if show(.effects) { section("Effects", [.effect]) }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
        }
    }

    private func show(_ f: Filter) -> Bool { filter == .all || filter == f }

    /// Generator category folders (`lowpoly`), in browser order.
    private var generatorCategories: [String] {
        engine.tools.compactMap(\.category).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    @ViewBuilder
    private func section(_ title: String, _ kinds: [DeviceKind], category: String? = nil) -> some View {
        let tools = engine.tools.filter { kinds.contains($0.kind) && $0.category == category }.map(withDevices).compactMap(filtered)
        if !tools.isEmpty {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.top, 10).padding(.bottom, 3)
            ForEach(tools) { tool in
                let open = isExpanded(tool)
                ToolRow(tool: tool, expanded: open, inUse: toolInUse(tool)) { toggle(tool) }
                if open {
                    ForEach(tool.presets) { preset in
                        PresetRow(tool: tool, preset: preset, inUse: presetInUse(tool, preset))
                    }
                }
            }
        }
    }

    /// Audio In, MIDI Input and Webcam list their sources and connected devices where other
    /// tools list presets.
    private func withDevices(_ tool: Tool) -> Tool {
        guard tool.kind == .input, ["audio", "midi", "webcam"].contains(tool.name) else { return tool }
        let devices: [PresetInfo]
        switch tool.name {
        case "audio":
            let captures = engine.audioCaptures
            let sources = [AudioCapture.Source.rekordbox, .systemAudio] + captures.inputDevices.map { .input(uid: $0.id) }
            devices = sources.map { PresetInfo(id: $0.key, name: captures.label($0), colors: []) }
        case "midi": devices = engine.midi.devices.map { PresetInfo(id: $0.name, name: $0.name, colors: []) }
        default: devices = engine.webcams.devices.map { PresetInfo(id: $0.name, name: $0.name, colors: []) }
        }
        return Tool(kind: tool.kind, name: tool.name, label: tool.label, cardinality: tool.cardinality, presets: devices, category: tool.category)
    }

    /// While searching, keeps a tool if its name matches (with all presets) or only its matching presets.
    private func filtered(_ tool: Tool) -> Tool? {
        guard !search.isEmpty else { return tool }
        if tool.label.localizedCaseInsensitiveContains(search) { return tool }
        let presets = tool.presets.filter { $0.name.localizedCaseInsensitiveContains(search) }
        return presets.isEmpty ? nil : Tool(kind: tool.kind, name: tool.name, label: tool.label, cardinality: tool.cardinality, presets: presets, category: tool.category)
    }

    private var expanded: Set<String> { Set(expandedRaw.split(separator: ",").map(String.init)) }

    private func isExpanded(_ tool: Tool) -> Bool {
        !tool.presets.isEmpty && (!search.isEmpty || expanded.contains(tool.id))
    }

    private func toggle(_ tool: Tool) {
        var set = expanded
        if set.contains(tool.id) { set.remove(tool.id) } else { set.insert(tool.id) }
        expandedRaw = set.sorted().joined(separator: ",")
    }

    private func toolInUse(_ tool: Tool) -> Bool {
        guard let scene = engine.current else { return false }
        switch tool.kind {
        case .input: return tool.name == "audio" ? scene.hasAudioInput : tool.name == "clock" ? scene.hasClock : false
        case .camera: return scene.cameraMotion?.rig.rawValue == tool.name
        case .palette: return scene.palette != nil
        case .generator: return scene.generators.contains { $0.type == tool.name }
        default: return false
        }
    }

    private func presetInUse(_ tool: Tool, _ preset: PresetInfo) -> Bool {
        guard let scene = engine.current else { return false }
        switch tool.kind {
        case .camera: return scene.cameraMotion?.rig.rawValue == tool.name && scene.cameraPreset == preset.id
        case .palette: return scene.palette != nil && scene.palettePreset == preset.id
        case .generator: return scene.generators.contains { $0.type == tool.name && $0.preset == preset.id }
        case .input:
            switch tool.name {
            case "audio": return scene.audioIn?.capture.source.key == preset.id
            case "midi": return scene.midiInputs.contains { $0.device == preset.id }
            default: return scene.webcams.contains { $0.device == preset.id }
            }
        default: return false
        }
    }

    static func icon(_ tool: Tool) -> String {
        switch tool.kind {
        case .input:
            switch tool.name {
            case "clock": return "metronome"
            case "midi": return "pianokeys"
            case "webcam": return "video"
            default: return "waveform"
            }
        case .modulation: return "waveform.path"
        case .camera: return CameraRig(rawValue: tool.name)?.icon ?? "camera.viewfinder"
        case .palette: return "paintpalette"
        case .generator:
            switch tool.name {
            case "sphere": return "circle.circle"
            case "torus": return "circle.dotted.circle"
            case "plane": return "square.grid.3x3"
            case "cube": return "cube"
            case "shards": return "sparkle"
            case "wheel": return "fanblades"
            default: return "cube.transparent"
            }
        case .effect:
            switch tool.name {
            case "feedback": return "arrow.triangle.2.circlepath"
            case "warp": return "water.waves"
            case "kaleido": return "camera.filters"
            case "chroma": return "circle.lefthalf.filled"
            case "glitch": return "bolt.horizontal"
            case "palettemap": return "paintpalette"
            case "pixelate": return "squareshape.split.3x3"
            case "glow": return "sun.max"
            case "film": return "film"
            case "mirror": return "arrow.left.and.right.square"
            case "slices": return "rectangle.split.3x1"
            default: return "sparkles"
            }
        }
    }

    static func color(_ kind: DeviceKind) -> Color {
        switch kind {
        case .input: return Theme.beatOn
        case .modulation: return Theme.modulation
        case .effect: return Theme.modulation
        default: return Theme.accent
        }
    }
}

private struct ToolRow: View {
    @Environment(Engine.self) private var engine
    let tool: Tool
    let expanded: Bool
    let inUse: Bool
    let onToggle: () -> Void

    var body: some View {
        BrowserRowChrome(add: { engine.apply(tool.kind, tool.name) }, inUse: inUse,
                         drag: .device(tool.kind, tool: tool.name, preset: nil)) {
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(tool.presets.isEmpty ? 0 : 1)
            .disabled(tool.presets.isEmpty)
            Image(systemName: DeviceBrowser.icon(tool))
                .font(.system(size: 11))
                .foregroundStyle(tool.name == "lfo" ? Theme.modulation : tool.name == "midi" ? Theme.midi : DeviceBrowser.color(tool.kind))
                .frame(width: 16)
            Text(tool.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
            if !tool.presets.isEmpty {
                Text("\(tool.presets.count)").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .help(tool.presets.isEmpty ? "Drag onto the chain, or double-click to add"
                                   : "Drag to add with default settings, or open it to pick a preset")
    }
}

private struct PresetRow: View {
    @Environment(Engine.self) private var engine
    let tool: Tool
    let preset: PresetInfo
    let inUse: Bool

    var body: some View {
        BrowserRowChrome(add: { engine.apply(tool.kind, tool.name, preset: preset.id) }, inUse: inUse,
                         drag: .device(tool.kind, tool: tool.name, preset: preset.id)) {
            Color.clear.frame(width: 18)
            let colors = preset.colors.compactMap(parseHexColor)
            if colors.isEmpty {
                Image(systemName: tool.name == "midi" ? "cable.connector" : tool.name == "webcam" ? "web.camera" : "doc.text")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            } else {
                LinearGradient(colors: colors.map(PaletteEditor.color), startPoint: .leading, endPoint: .trailing)
                    .frame(width: 16, height: 10)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }
            Text(preset.name).font(.system(size: 11)).lineLimit(1)
        }
        .help(tool.name == "midi" ? "Add a MIDI Input listening to \(preset.name)"
              : tool.name == "webcam" ? "Add a Webcam using \(preset.name)"
                                  : "\(tool.label) preset. Drag onto the chain, or double-click to add")
    }
}

/// Shared row behaviour: hover highlight, + button, double-click to add, and drag source.
private struct BrowserRowChrome<Content: View>: View {
    @Environment(Engine.self) private var engine
    let add: () -> Void
    let inUse: Bool
    let drag: ChainDrag
    @ViewBuilder let content: Content
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            content
            Spacer(minLength: 4)
            if inUse {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            } else if hovered {
                Button(action: add) { Image(systemName: "plus.circle.fill").font(.system(size: 12)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .help("Add to the chain")
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 4).fill(hovered ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        // One tap handler reading clickCount rather than a count-2 gesture, so a first click
        // is never held back waiting for a second.
        .onTapGesture { if NSApp.currentEvent?.clickCount == 2 { add() } }
        .chainDragSource(drag, engine: engine)
    }
}
