import SwiftUI

struct ContentView: View {
    @Environment(Engine.self) private var engine
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var engine = engine
        NavigationSplitView {
            // Scenes (or playlists) on top, device browser below, like Ableton's left-hand
            // browser. Mappings live in the inspector on the right.
            VSplitView {
                VStack(spacing: 0) {
                    Picker("", selection: Binding(get: { engine.playlists.tab }, set: { engine.playlists.tab = $0 })) {
                        ForEach(SidebarTab.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    switch engine.playlists.tab {
                    case .scenes: SceneList()
                    case .playlists: PlaylistList()
                    }
                }
                .frame(minHeight: 110, idealHeight: 200)
                DeviceBrowser()
                    .frame(minHeight: 180, idealHeight: 420)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            VStack(spacing: 0) {
                PreviewArea()
                Divider()
                if let scene = engine.current {
                    DeviceChain(scene: scene)
                        .frame(height: 252)
                } else {
                    Text("No scene loaded")
                        .foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity)
                        .frame(height: 252)
                        .background(Theme.chainBackground)
                }
                Divider()
                PlaylistBar()
                Divider()
                StatusBar()
            }
            .toolbar { TransportToolbar() }
            .inspector(isPresented: $engine.showInspector) {
                MappingsInspector()
                    .inspectorColumnWidth(min: 250, ideal: 290, max: 420)
            }
            // Esc leaves map mode and MIDI learning.
            .background {
                Button("") { engine.mapSource = nil; engine.current?.learnMIDI(nil); engine.playlists.mapMode = false; engine.learnPlaylistMIDI(nil) }
                    .keyboardShortcut(.escape, modifiers: [])
                    .opacity(0)
                    .disabled(engine.mapSource == nil && engine.current?.learningMIDI == nil && !engine.playlists.mapMode)
            }
        }
        .navigationTitle(engine.current?.name ?? "jim-viz")
        .navigationSubtitle(engine.isDirty ? "Edited" : "")
        .onAppear { engine.undoManager = undoManager }
        .onChange(of: undoManager) { _, um in engine.undoManager = um }
        .alert(
            "Delete “\(engine.scenePendingDeletion.map { engine.sceneName($0) } ?? "Scene")”?",
            isPresented: Binding(
                get: { engine.scenePendingDeletion != nil },
                set: { if !$0 { engine.scenePendingDeletion = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                engine.scenePendingDeletion = nil
            }
            Button("Delete", role: .destructive) {
                if let url = engine.scenePendingDeletion {
                    engine.deleteScene(url)
                    engine.scenePendingDeletion = nil
                }
            }
        } message: {
            Text("Are you sure you want to delete this scene? The file will be removed from Content/Scenes.")
        }
    }
}

private struct SceneList: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        List(selection: Binding(get: { engine.currentURL }, set: { if let u = $0 { engine.selectDevice(nil); engine.load(u) } })) {
            Section {
                ForEach(engine.sceneURLs, id: \.self) { url in
                    SceneRow(url: url).tag(url)
                        // The list's own drag, which leaves clicks to selection (onDrag on a row doesn't).
                        .itemProvider { PlaylistDrag.scene(url.deletingPathExtension().lastPathComponent).provider(engine) }
                }
            } header: {
                HStack(spacing: 8) {
                    Text("Scenes")
                    Spacer()
                    Button { NSWorkspace.shared.open(engine.contentRoot) } label: { Image(systemName: "folder") }
                        .help("Open Content Folder")
                    Button { engine.createNewScene() } label: { Image(systemName: "plus") }
                        .help("New Empty Scene (⌘N)")
                }
                .buttonStyle(.plain)
            }
        }
        // The list's own menu and double-click action, so row clicks still select (load) scenes.
        .contextMenu(forSelectionType: URL.self) { urls in
            if let url = urls.first {
                Button("Rename") { engine.renamingScene = url }
                Button("Duplicate") { engine.duplicateScene(url) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Divider()
                Button("Delete…", role: .destructive) { engine.scenePendingDeletion = url }
            }
        } primaryAction: { urls in
            if let url = urls.first { engine.renamingScene = url }
        }
        .listStyle(.sidebar)
    }
}

/// A scene in the list. Double-click it (or right-click → Rename) to rename it;
/// Return saves, Esc cancels.
private struct SceneRow: View {
    @Environment(Engine.self) private var engine
    let url: URL
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if engine.renamingScene == url {
            Label {
                TextField("Scene name", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { engine.renameScene(url, to: draft) }
                    .onExitCommand { engine.renamingScene = nil }
                    .onChange(of: focused) { _, on in
                        // Clicking away commits, like Finder.
                        if !on, engine.renamingScene == url { engine.renameScene(url, to: draft) }
                    }
            } icon: { Image(systemName: "cube.transparent") }
            .onAppear { draft = engine.sceneName(url); DispatchQueue.main.async { focused = true } }
        } else {
            Label(engine.sceneName(url), systemImage: "cube.transparent")
                .help(url.lastPathComponent)
        }
    }
}

private struct PreviewArea: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.previewBackground
            MetalPreview(engine: engine)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(10)
        }
        .frame(minHeight: 240)
    }
}

private struct MetalPreview: NSViewRepresentable {
    let engine: Engine
    func makeNSView(context: Context) -> MetalSurfaceView {
        MetalSurfaceView(device: engine.device, loop: engine.loop)
    }
    func updateNSView(_ nsView: MetalSurfaceView, context: Context) {}
}

private struct TransportToolbar: ToolbarContent {
    @Environment(Engine.self) private var engine

    var body: some ToolbarContent {
        @Bindable var engine = engine
        ToolbarItemGroup(placement: .primaryAction) {
            OutputMenu(output: engine.output)
            Button { engine.togglePlaylistBar() } label: { Label("Playlist", systemImage: "rectangle.bottomthird.inset.filled") }
                .help("Show or hide the playlist (⇧⌘Y)")
            Button { engine.showInspector.toggle() } label: { Label("Mappings", systemImage: "sidebar.right") }
                .help("Show or hide the mappings inspector (⌥⌘0)")
        }
    }
}

private struct OutputMenu: View {
    let output: OutputController

    var body: some View {
        Menu {
            Button("Off") { output.setMode(.off) }
            Button("Windowed") { output.setMode(.windowed) }
            Divider()
            ForEach(output.screens) { s in
                Button("Fullscreen on \(s.name) (\(Int(s.pixelSize.width))×\(Int(s.pixelSize.height)))") {
                    output.setMode(.fullscreen(s.id))
                }
            }
        } label: {
            Label(output.modeLabel, systemImage: isLive ? "play.display" : "display")
        }
        .help("Where the visuals are shown. ⇧⌘F toggles fullscreen on the projector.")
    }

    private var isLive: Bool { output.mode != .off }
}

private struct StatusBar: View {
    @Environment(Engine.self) private var engine

    var body: some View {
        HStack(spacing: 8) {
            if let err = engine.errorSummary {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.error)
                Text(err)
                    .foregroundStyle(Theme.error)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(engine.errors.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n\n"))
                    .textSelection(.enabled)
            } else {
                Text(engine.info).foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "GPU %.1f ms   %.0f fps", engine.gpuMs, engine.fps))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(Theme.chainBackground)
    }
}
