import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What a drag onto the playlist bar carries: a scene from the list, or an entry being moved.
enum PlaylistDrag {
    case scene(String)
    case entry(Int)

    var token: String {
        switch self {
        case .scene(let slug): return "jim-viz.scene:\(slug)"
        case .entry(let i): return "jim-viz.entry:\(i)"
        }
    }

    init?(token: String) {
        if token.hasPrefix("jim-viz.scene:") { self = .scene(String(token.dropFirst(14))) }
        else if token.hasPrefix("jim-viz.entry:"), let i = Int(token.dropFirst(14)) { self = .entry(i) }
        else { return nil }
    }

    func provider(_ engine: Engine) -> NSItemProvider {
        // Not a chain drag: clear any stale one so the chain doesn't show a drop point.
        engine.activeDrag = nil
        return NSItemProvider(object: token as NSString)
    }

    /// Reads the drag from dropped providers, on main.
    static func load(_ providers: [NSItemProvider], _ done: @escaping (PlaylistDrag) -> Void) -> Bool {
        guard let p = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String, let drag = PlaylistDrag(token: s) else { return }
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

// MARK: - Sidebar

/// The playlists in `<library>/Playlists`. Selecting one opens it in the bottom bar; one
/// always stays selected.
struct PlaylistList: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        let state = engine.playlists
        List(selection: Binding(get: { state.selectedURL }, set: { if let url = $0 { engine.selectPlaylist(url) } })) {
            Section {
                ForEach(state.urls, id: \.self) { url in
                    PlaylistRow(url: url).tag(url)
                }
            } header: {
                HStack(spacing: 8) {
                    Text("Playlists")
                    Spacer()
                    Button { engine.createPlaylist() } label: { Image(systemName: "plus") }
                        .help("New Playlist")
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu(forSelectionType: URL.self) { urls in
            if let url = urls.first {
                Button("Rename") { state.renaming = url }
                Button("Duplicate") { engine.duplicatePlaylist(url) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Divider()
                Button("Delete…", role: .destructive) { state.pendingDeletion = url }
            }
        } primaryAction: { urls in
            if let url = urls.first { state.renaming = url }
        }
        .listStyle(.sidebar)
        .alert(
            "Delete “\(state.pendingDeletion.map { state.name($0) } ?? "Playlist")”?",
            isPresented: Binding(get: { state.pendingDeletion != nil }, set: { if !$0 { state.pendingDeletion = nil } })
        ) {
            Button("Cancel", role: .cancel) { state.pendingDeletion = nil }
            Button("Delete", role: .destructive) {
                if let url = state.pendingDeletion { engine.deletePlaylist(url) }
                state.pendingDeletion = nil
            }
        } message: {
            Text("The file will be removed from the library’s Playlists folder. Its scenes stay.")
        }
    }
}

/// A playlist in the list. Double-click (or right-click → Rename) to rename; Return saves, Esc cancels.
private struct PlaylistRow: View {
    @Environment(Engine.self) private var engine
    let url: URL
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let state = engine.playlists
        if state.renaming == url {
            Label {
                TextField("Playlist name", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { engine.renamePlaylist(url, to: draft) }
                    .onExitCommand { state.renaming = nil }
                    .onChange(of: focused) { _, on in
                        if !on, state.renaming == url { engine.renamePlaylist(url, to: draft) }
                    }
            } icon: { Image(systemName: "list.bullet.rectangle") }
            .onAppear { draft = state.name(url); DispatchQueue.main.async { focused = true } }
        } else {
            Label(state.name(url), systemImage: "list.bullet.rectangle")
                .help(url.lastPathComponent)
        }
    }
}

// MARK: - Bottom bar

/// The bottom bar: the open playlist, left to right. Scenes are blocks, the transitions
/// between them the links, and a last slot adds a scene. The link before that slot is the
/// transition from the last scene back to the first, as the playlist loops. The triangle
/// folds it to its header, which keeps the transport. With no playlists it offers to make one.
struct PlaylistBar: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        let state = engine.playlists
        VStack(spacing: 0) {
            header(state)
            if state.expanded {
                Group {
                    if let file = state.file {
                        ScrollView(.horizontal) {
                            HStack(spacing: 0) {
                                ForEach(Array(file.entries.enumerated()), id: \.offset) { i, entry in
                                    PlaylistSlot(index: i, entry: entry)
                                    TransitionLink(index: i, spec: entry.transition)
                                }
                                AddSceneSlot(index: file.entries.count)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                        }
                        .scrollIndicators(.visible)
                    } else if state.selectedURL == nil {
                        HStack(spacing: 10) {
                            Text("No playlists yet").foregroundStyle(Theme.textDim)
                            Button("New Playlist") { engine.createPlaylist() }
                                .controlSize(.small)
                        }
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // The file didn't load; its error is in the status bar.
                        Color.clear
                    }
                }
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
                Text(state.selectedURL.map(state.name) ?? "Playlists").font(Theme.titleFont).foregroundStyle(Theme.text)
                    .contentShape(Rectangle())
                    .onTapGesture { engine.togglePlaylistBar() }
            }
            .fixedSize()
            .help(state.expanded ? "Hide the playlist (⇧⌘Y)" : "Show the playlist (⇧⌘Y)")
            if let file = state.file, !file.entries.isEmpty {
                Text(state.position.map { "\($0 + 1) of \(file.entries.count)" } ?? "\(file.entries.count) scenes")
                    .font(Theme.valueFont).foregroundStyle(Theme.textDim)
            }
            Spacer()
            if state.selectedURL != nil {
                TransportButton(action: .previous)
                TransportButton(action: .next)
                Toggle(isOn: Binding(get: { state.mapMode }, set: { state.mapMode = $0; engine.learnPlaylistMIDI(nil) })) {
                    Image(systemName: "keyboard")
                }
                .toggleStyle(.button)
                .tint(Theme.midi)
                .controlSize(.small)
                .help("MIDI map: click Previous or Next, then press a pad, key or button on your controller")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Theme.deviceHeader)
    }
}

/// Previous or Next. In MIDI map mode, clicking it waits for a control instead of stepping;
/// its binding shows beside it.
private struct TransportButton: View {
    @Environment(Engine.self) private var engine
    let action: PlaylistAction

    var body: some View {
        let state = engine.playlists
        let learning = state.learning == action
        let binding = state.bindings[action]
        HStack(spacing: 4) {
            Button {
                if state.mapMode { engine.learnPlaylistMIDI(learning ? nil : action) }
                else { engine.stepPlaylist(action == .next ? 1 : -1) }
            } label: {
                Image(systemName: action == .next ? "forward.end.fill" : "backward.end.fill")
                    .frame(width: 18)
            }
            .controlSize(.small)
            .tint(state.mapMode ? Theme.midi : nil)
            .buttonStyle(.borderedProminent)
            .overlay {
                if state.mapMode {
                    RoundedRectangle(cornerRadius: 5).stroke(learning ? Color.white : Theme.midi, lineWidth: learning ? 2 : 1)
                }
            }
            .disabled(!state.mapMode && !engine.playlistActive)
            .help("\(action.label) (⌘\(action == .next ? "]" : "["))" + (binding.map { " · MIDI \($0.label)" } ?? ""))
            .contextMenu {
                if binding != nil { Button("Clear MIDI Mapping") { engine.clearPlaylistMIDI(action) } }
            }
            if state.mapMode {
                Text(learning ? "Press a control…" : binding?.label ?? "Unmapped")
                    .font(Theme.labelFont)
                    .foregroundStyle(learning ? Color.white : binding == nil ? Theme.textDim : Theme.midi)
                    .lineLimit(1)
            }
        }
    }
}

private struct SlotBox<Content: View>: View {
    var highlighted = false
    var dashed = false
    var dropping = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 10)
            .frame(width: 140, height: 46)
            .background(RoundedRectangle(cornerRadius: 4).fill(dashed ? Color.clear : highlighted ? Theme.deviceHeaderSelected : Theme.device))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(dropping ? Theme.accent : highlighted ? Theme.accent : dashed ? Theme.knobTrack : Theme.deviceBorder,
                            style: StrokeStyle(lineWidth: dropping || highlighted ? 2 : 1, dash: dashed && !dropping ? [4, 3] : []))
            }
    }
}

/// A scene in the playlist. Click to play it; drag to reorder; drop a scene on it to insert
/// before it.
private struct PlaylistSlot: View {
    @Environment(Engine.self) private var engine
    let index: Int
    let entry: PlaylistEntry
    @State private var dropping = false

    var body: some View {
        let url = engine.playlistSceneURL(entry.scene)
        let playing = engine.playlists.position == index
        SlotBox(highlighted: playing, dropping: dropping) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(index + 1)").font(Theme.valueFont).foregroundStyle(Theme.textDim)
                Text(url.map(engine.sceneName) ?? entry.scene)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(url == nil ? Theme.error : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture { engine.playPlaylistEntry(index) }
        .onDrag { PlaylistDrag.entry(index).provider(engine) }
        .onDrop(of: [.plainText], isTargeted: $dropping) { providers in
            PlaylistDrag.load(providers) { drag in
                switch drag {
                case .scene(let slug): engine.insertPlaylistScene(slug, at: index)
                case .entry(let from): engine.movePlaylistEntry(from: from, to: index)
                }
            }
        }
        .contextMenu {
            Button("Play") { engine.playPlaylistEntry(index) }
            Divider()
            Button("Remove from Playlist", role: .destructive) { engine.removePlaylistEntry(index) }
        }
        .help(url == nil ? "“\(entry.scene)” isn't in the library’s Scenes folder" : "Click to play, drag to reorder")
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

/// The empty slot at the end. Pick a scene from its menu, or drop one on it.
private struct AddSceneSlot: View {
    @Environment(Engine.self) private var engine
    let index: Int
    @State private var dropping = false

    var body: some View {
        Menu {
            ForEach(engine.sceneURLs, id: \.self) { url in
                Button(engine.sceneName(url)) { engine.insertPlaylistScene(url.deletingPathExtension().lastPathComponent) }
            }
        } label: {
            SlotBox(dashed: true, dropping: dropping) {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                    Text("Select scene")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onDrop(of: [.plainText], isTargeted: $dropping) { providers in
            PlaylistDrag.load(providers) { drag in
                switch drag {
                case .scene(let slug): engine.insertPlaylistScene(slug)
                case .entry(let from): engine.movePlaylistEntry(from: from, to: index)
                }
            }
        }
        .help("Add a scene: pick one, or drag one here from the Scenes list")
    }
}
