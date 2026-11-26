import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What a drag within the Scenes list carries: a scene or a folder.
enum LibraryDrag {
    case scene(String)
    case folder(String)

    var token: String {
        switch self {
        case .scene(let slug): return "jim-viz.scene:\(slug)"
        case .folder(let name): return "jim-viz.folder:\(name)"
        }
    }

    init?(token: String) {
        func rest(_ prefix: String) -> String? { token.hasPrefix(prefix) ? String(token.dropFirst(prefix.count)) : nil }
        if let slug = rest("jim-viz.scene:") { self = .scene(slug) }
        else if let name = rest("jim-viz.folder:") { self = .folder(name) }
        else { return nil }
    }

    func provider(_ engine: Engine) -> NSItemProvider {
        // Not a chain drag: clear any stale one so the chain doesn't show a drop point.
        engine.activeDrag = nil
        return NSItemProvider(object: token as NSString)
    }

    /// Reads the drag from dropped providers, on main.
    static func load(_ providers: [NSItemProvider], _ done: @escaping (LibraryDrag) -> Void) -> Bool {
        guard let p = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String, let drag = LibraryDrag(token: s) else { return }
            DispatchQueue.main.async { done(drag) }
        }
        return true
    }
}

extension Engine {
    /// Folds or unfolds the playlist bar, sliding the views above it like the sidebars.
    func togglePlaylistBar() {
        withAnimation(.easeInOut(duration: 0.2)) { playlists.expanded.toggle() }
    }
}

// MARK: - Bottom bar

/// The bottom bar: the playlist the scene playing is in (its sidebar folder), left to right.
/// Scenes are blocks and the transitions between them the links; the last link is the
/// transition from the last scene back to the first, as the playlist loops. The order is the
/// folder's, set in the sidebar; here you play scenes and set transitions. The triangle folds it
/// to its header, which keeps the transport. Shown only while the scene playing is in a folder.
struct PlaylistBar: View {
    @Environment(Engine.self) private var engine
    let playlist: SidebarFolder

    var body: some View {
        let state = engine.playlists
        VStack(spacing: 0) {
            header(state)
            if state.expanded {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(Array(playlist.entries.enumerated()), id: \.offset) { i, entry in
                            PlaylistSlot(index: i, entry: entry)
                            TransitionLink(index: i, spec: entry.transition)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.visible)
                .frame(height: 72)
                .transition(.opacity)
            }
        }
        .background(Theme.chainBackground)
    }

    private func header(_ state: PlaylistState) -> some View {
        HStack(spacing: 6) {
            // The native disclosure triangle, used for its label only: the bar below is the content.
            DisclosureGroup(isExpanded: Binding(get: { state.expanded }, set: { if $0 != state.expanded { engine.togglePlaylistBar() } })) {
                EmptyView()
            } label: {
                Text(playlist.name).font(Theme.titleFont).foregroundStyle(Theme.text)
                    .contentShape(Rectangle())
                    .onTapGesture { engine.togglePlaylistBar() }
            }
            .fixedSize()
            .help(state.expanded ? "Hide the playlist (⇧⌘Y)" : "Show the playlist (⇧⌘Y)")
            if let position = engine.playlistPosition {
                Text("\(position + 1) of \(playlist.entries.count)")
                    .font(Theme.valueFont).foregroundStyle(Theme.textDim)
            }
            Spacer()
            TransportButton(next: false)
            TransportButton(next: true)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Theme.deviceHeader)
    }
}

/// Previous or Next. In MIDI map mode (the toolbar's keyboard button), clicking it waits for a
/// control instead of stepping, and its mapping shows beside it.
private struct TransportButton: View {
    @Environment(Engine.self) private var engine
    let next: Bool

    var body: some View {
        let map = engine.midiMap
        let target = next ? MIDIMap.nextKey : MIDIMap.previousKey
        let learning = map.isOn && map.learning == target
        let mapping = engine.mappings(for: target).first
        let control = mapping.flatMap { MIDIControl(sourceKey: $0.source) }
        HStack(spacing: 4) {
            Button {
                if map.isOn { engine.learnMIDI(target) }
                else { engine.stepPlaylist(next ? 1 : -1) }
            } label: {
                Image(systemName: next ? "forward.end.fill" : "backward.end.fill")
                    .frame(width: 18)
            }
            .controlSize(.small)
            .tint(map.isOn ? Theme.midi : nil)
            .buttonStyle(.borderedProminent)
            .overlay {
                if map.isOn {
                    RoundedRectangle(cornerRadius: 5).stroke(learning ? Color.white : Theme.midi, lineWidth: learning ? 2 : 1)
                }
            }
            .disabled(!map.isOn && !engine.playlistActive)
            .help("\(MIDIMap.label(target)) (⌘\(next ? "]" : "["))" + (control.map { " · MIDI \($0.label)" } ?? ""))
            .contextMenu {
                if mapping != nil { Button("Clear MIDI Mapping") { engine.removeMappings(target: target) } }
            }
            if map.isOn {
                Text(learning ? "Move a control…" : control?.label ?? "Unmapped")
                    .font(Theme.labelFont)
                    .foregroundStyle(learning ? Color.white : control == nil ? Theme.textDim : Theme.midi)
                    .lineLimit(1)
            }
        }
    }
}

/// A scene in the playlist. Click to play it.
private struct PlaylistSlot: View {
    @Environment(Engine.self) private var engine
    let index: Int
    let entry: PlaylistEntry

    var body: some View {
        let url = engine.sceneURL(entry.scene)
        let playing = engine.playlistPosition == index
        VStack(alignment: .leading, spacing: 2) {
            Text("\(index + 1)").font(Theme.valueFont).foregroundStyle(Theme.textDim)
            Text(url.map(engine.sceneName) ?? entry.scene)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .frame(width: 140, height: 46)
        .background(RoundedRectangle(cornerRadius: 4).fill(playing ? Theme.deviceHeaderSelected : Theme.device))
        .overlay {
            RoundedRectangle(cornerRadius: 4).stroke(playing ? Theme.accent : Theme.deviceBorder, lineWidth: playing ? 2 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { engine.playPlaylistEntry(index) }
        .help("Click to play. Reorder it in the sidebar folder.")
    }
}

/// The link after entry `index`: the transition into the next scene (or back to the first).
/// Click it to change it.
private struct TransitionLink: View {
    @Environment(Engine.self) private var engine
    let index: Int
    let spec: TransitionSpec
    @State private var editing = false

    var body: some View {
        HStack(spacing: 0) {
            line
            Button { editing = true } label: {
                Text(spec.label)
                    .font(Theme.labelFont)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.deviceHeader))
                    .overlay(Capsule().stroke(editing ? Theme.accent : Theme.deviceBorder))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $editing, arrowEdge: .bottom) {
                TransitionEditor(spec: spec) { engine.setPlaylistTransition(index, $0) }
            }
            line
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.knobTrack)
        }
        .padding(.horizontal, 4)
        .help("Transition into the next scene. Click to change.")
    }

    private var line: some View { Rectangle().fill(Theme.knobTrack).frame(width: 10, height: 1) }
}

private struct TransitionEditor: View {
    @State var spec: TransitionSpec
    let commit: (TransitionSpec) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Type", selection: $spec.type) {
                ForEach(TransitionType.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            HStack {
                Text("Duration")
                Slider(value: Binding(get: { min(spec.duration, 2) }, set: { spec.duration = ($0 * 100).rounded() / 100 }), in: 0...2)
                    .frame(width: 140)
                TextField("ms", value: Binding(get: { Int((spec.duration * 1000).rounded()) },
                                               set: { spec.duration = Double($0) / 1000 }), format: .number)
                    .frame(width: 56)
                    .multilineTextAlignment(.trailing)
                Text("ms").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .controlSize(.small)
        .padding(12)
        .frame(width: 300)
        .onChange(of: spec) { _, s in commit(s) }
    }
}
