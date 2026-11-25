import SwiftUI
import UniformTypeIdentifiers

/// The Scenes list, in the order and folders kept in `Sidebar.json`. Drag a row to reorder it
/// or to move it into or out of a folder (onto the folder, or between its rows), or right-click
/// it and pick Move to; the folder button in the header adds a folder. A folder is a playlist:
/// its order is the play order, and the bottom bar sets its transitions. Clicking a folder
/// loads its first scene.
/// The scene files stay where they are.
struct SidebarList<Row: View, FileMenu: View>: View {
    @Environment(Engine.self) private var engine
    let urls: [URL]
    let selected: URL?
    let select: (URL) -> Void
    /// Double-click on a file.
    let rename: (URL) -> Void
    let newHelp: String
    let new: () -> Void
    @ViewBuilder let row: (URL) -> Row
    @ViewBuilder let menu: (URL) -> FileMenu

    var body: some View {
        let bySlug = Dictionary(uniqueKeysWithValues: urls.map { ($0.deletingPathExtension().lastPathComponent, $0) })
        List(selection: Binding(get: { selected }, set: { if let url = $0 { select(url) } })) {
            Section {
                ForEach(engine.sidebar.file.scenes) { item in
                    switch item {
                    case .scene(let slug):
                        file(slug, bySlug)
                    case .folder(let folder):
                        DisclosureGroup(isExpanded: Binding(get: { folder.open }, set: { open in
                            engine.editSidebar { $0.setFolder(folder.name, open: open) }
                        })) {
                            ForEach(folder.scenes, id: \.self) { file($0, bySlug) }
                                .onInsert(of: [.plainText]) { index, providers in drop(providers, into: folder.name, at: index) }
                        } label: {
                            SidebarFolderRow(name: folder.name, first: folder.scenes.first.flatMap { bySlug[$0] }) { drop($0, into: folder.name, at: nil) }
                        }
                        // The folder's own drag; its files' rows carry theirs.
                        .itemProvider { LibraryDrag.folder(folder.name).provider(engine) }
                    }
                }
                .onInsert(of: [.plainText]) { index, providers in drop(providers, into: nil, at: index) }
            } header: {
                HStack(spacing: 8) {
                    Text("Scenes")
                    Spacer()
                    Button { engine.createSidebarFolder() } label: { Image(systemName: "folder.badge.plus") }
                        .help("New Folder")
                    Button(action: new) { Image(systemName: "plus") }
                        .help(newHelp)
                }
                .buttonStyle(.plain)
            }
        }
        // The list's own menu and double-click action, so row clicks still select.
        .contextMenu(forSelectionType: URL.self) { urls in
            if let url = urls.first {
                menu(url)
                moveMenu(url.deletingPathExtension().lastPathComponent)
            }
        } primaryAction: { urls in
            if let url = urls.first { rename(url) }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func file(_ slug: String, _ bySlug: [String: URL]) -> some View {
        if let url = bySlug[slug] {
            row(url).tag(url)
                // The list's own drag, which leaves clicks to selection (onDrag on a row doesn't).
                .itemProvider { LibraryDrag.scene(slug).provider(engine) }
        }
    }

    /// Move to ▸ each folder but the file's own, and out to the list.
    @ViewBuilder
    private func moveMenu(_ slug: String) -> some View {
        let items = engine.sidebar.file.scenes
        if !items.folders.isEmpty {
            let inFolder = !items.contains(.scene(slug))
            Divider()
            Menu("Move to") {
                ForEach(items, id: \.id) { item in
                    if case .folder(let folder) = item, !folder.scenes.contains(slug) {
                        Button(folder.name) { engine.editSidebar { $0.move(scene: slug, toFolder: folder.name) } }
                    }
                }
                if inFolder {
                    Divider()
                    Button("Top of the List") { engine.editSidebar { $0.move(scene: slug, toFolder: nil, at: 0) } }
                }
            }
        }
    }

    /// A row dropped into a folder (nil for the top level), before the row at `index` or at the end.
    private func drop(_ providers: [NSItemProvider], into folder: String?, at index: Int?) {
        _ = LibraryDrag.load(providers) { drag in
            switch drag {
            case .scene(let slug):
                engine.editSidebar { $0.move(scene: slug, toFolder: folder, at: index) }
            case .folder(let name):
                // Folders don't nest: one dropped among another's rows stays where it was.
                if folder == nil, let index { engine.editSidebar { $0.move(folder: name, to: index) } }
            }
        }
    }
}

/// A folder (a playlist) in the list. Click to load its first scene. Double-click (or
/// right-click → Rename) to rename; Return saves, Esc cancels. A row dropped on it goes to its
/// end. Deleting it leaves its scenes in the list and drops its transitions.
private struct SidebarFolderRow: View {
    @Environment(Engine.self) private var engine
    let name: String
    /// Its first scene's file, loaded on a click.
    let first: URL?
    let drop: ([NSItemProvider]) -> Void
    @State private var draft = ""
    @State private var dropping = false
    @FocusState private var focused: Bool

    var body: some View {
        let state = engine.sidebar
        Group {
            if state.renamingFolder == name {
                Label {
                    TextField("Folder name", text: $draft)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit { engine.renameSidebarFolder(name, to: draft) }
                        .onExitCommand { state.renamingFolder = nil }
                        .onChange(of: focused) { _, on in
                            if !on, state.renamingFolder == name { engine.renameSidebarFolder(name, to: draft) }
                        }
                } icon: { Image(systemName: "folder") }
                .onAppear { draft = name; DispatchQueue.main.async { focused = true } }
            } else {
                Label(name, systemImage: "folder")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(dropping ? Theme.accent.opacity(0.35) : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            if NSApp.currentEvent?.clickCount == 2 {
                state.renamingFolder = name
            } else if let first {
                engine.selectDevice(nil)
                engine.load(first)
            }
        }
        .onDrop(of: [.plainText], isTargeted: $dropping) { providers in
            drop(providers)
            return true
        }
        .contextMenu {
            Button("Rename") { state.renamingFolder = name }
            Divider()
            Button("Delete Folder") { engine.editSidebar { $0.removeFolder(name) } }
        }
    }
}
