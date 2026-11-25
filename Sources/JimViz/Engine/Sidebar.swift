import Foundation
import Observation

/// A row of the Scenes list: a scene, by its file name without `.json`, or a folder of them.
/// A folder is a playlist: its scenes play in its order, looping, with a transition on each
/// link. Folders hold scenes, not other folders, and each scene is listed once. The files on
/// disk stay flat in `Scenes`.
enum SidebarItem: Codable, Equatable, Identifiable {
    case scene(String)
    case folder(SidebarFolder)

    var id: String {
        switch self {
        case .scene(let slug): return "scene:\(slug)"
        case .folder(let folder): return "folder:\(folder.name)"
        }
    }

    /// In JSON a scene is its name and a folder an object.
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let slug = try? c.decode(String.self) { self = .scene(slug) } else { self = .folder(try c.decode(SidebarFolder.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .scene(let slug): try c.encode(slug)
        case .folder(let folder): try c.encode(folder)
        }
    }
}

/// A folder, which is a playlist: its scenes in play order, each with the transition into the
/// next. The last one's transition loops back to the first.
struct SidebarFolder: Codable, Equatable {
    var name: String
    /// Unfolded in the list.
    var open: Bool
    private(set) var entries: [PlaylistEntry]

    init(name: String, open: Bool, scenes: [String] = []) {
        self.name = name
        self.open = open
        entries = scenes.map { PlaylistEntry(scene: $0, transition: .default) }
    }

    var scenes: [String] { entries.map(\.scene) }

    private struct Link: Hashable {
        let from, to: String
    }

    /// Puts new scenes in, or the same ones in a new order. A link between the same two scenes
    /// as before keeps its transition; every other link gets the default.
    mutating func setScenes(_ new: [String]) {
        var kept: [Link: TransitionSpec] = [:]
        for (i, entry) in entries.enumerated() {
            kept[Link(from: entry.scene, to: entries[(i + 1) % entries.count].scene)] = entry.transition
        }
        entries = new.indices.map { i in
            PlaylistEntry(scene: new[i], transition: kept[Link(from: new[i], to: new[(i + 1) % new.count])] ?? .default)
        }
    }

    /// Sets the transition after entry `index`, into the next one.
    mutating func setTransition(_ index: Int, _ spec: TransitionSpec) {
        guard entries.indices.contains(index) else { return }
        entries[index].transition = spec
    }

    /// A scene's new file name. Its links keep their transitions.
    mutating func rename(scene old: String, to new: String) {
        for i in entries.indices where entries[i].scene == old { entries[i].scene = new }
    }

    /// The transition into entry `index`: the one on the link before it, wrapping around.
    func transition(into index: Int) -> TransitionSpec {
        entries[(index - 1 + entries.count) % entries.count].transition
    }
}

/// The order and folders of the Scenes list, in `<library>/Sidebar.json`. Without the file the
/// list is flat and in name order.
struct SidebarFile: Codable, Equatable {
    var scenes: [SidebarItem] = []

    struct Invalid: LocalizedError {
        let errorDescription: String?
    }

    /// Strict: a scene listed twice, or two folders with one name, is an error.
    static func load(_ url: URL) throws -> SidebarFile {
        let file = try JSONDecoder().decode(SidebarFile.self, from: Data(contentsOf: url))
        guard Set(file.scenes.scenes).count == file.scenes.scenes.count else { throw Invalid(errorDescription: "invalid shape: a scene is listed twice") }
        guard Set(file.scenes.folders).count == file.scenes.folders.count, !file.scenes.folders.contains("") else {
            throw Invalid(errorDescription: "invalid shape: folders need names of their own")
        }
        return file
    }

    func write(to url: URL) throws {
        try JSONEncoder.pretty.encode(self).write(to: url, options: .atomic)
    }
}

extension [SidebarItem] {
    /// Every scene, top to bottom, folders' scenes included.
    var scenes: [String] {
        flatMap { item -> [String] in
            switch item {
            case .scene(let slug): return [slug]
            case .folder(let folder): return folder.scenes
            }
        }
    }

    var folders: [String] {
        compactMap { if case .folder(let folder) = $0 { folder.name } else { nil } }
    }

    /// The folder a scene is in, if any.
    func folder(containing slug: String) -> SidebarFolder? {
        for case .folder(let folder) in self where folder.scenes.contains(slug) { return folder }
        return nil
    }

    private func folderIndex(_ name: String) -> Int? {
        firstIndex { if case .folder(let folder) = $0 { folder.name == name } else { false } }
    }

    private mutating func withFolder(_ name: String, _ change: (inout SidebarFolder) -> Void) {
        guard let i = folderIndex(name), case .folder(var folder) = self[i] else { return }
        change(&folder)
        self[i] = .folder(folder)
    }

    /// Follows the files on disk: drops the ones that are gone, and adds new ones at the end.
    mutating func reconcile(_ present: [String]) {
        let have = Set(present)
        self = compactMap { item in
            switch item {
            case .scene(let slug): return have.contains(slug) ? item : nil
            case .folder(var folder):
                if !folder.scenes.allSatisfy(have.contains) { folder.setScenes(folder.scenes.filter(have.contains)) }
                return .folder(folder)
            }
        }
        let listed = Set(scenes)
        append(contentsOf: present.filter { !listed.contains($0) }.map(SidebarItem.scene))
    }

    /// Takes a scene out of the top level or its folder, and says where it was.
    private mutating func remove(scene: String) -> (folder: String?, index: Int)? {
        if let i = firstIndex(of: .scene(scene)) {
            remove(at: i)
            return (nil, i)
        }
        for case .folder(let folder) in self {
            guard let i = folder.scenes.firstIndex(of: scene) else { continue }
            withFolder(folder.name) { $0.setScenes($0.scenes.filter { $0 != scene }) }
            return (folder.name, i)
        }
        return nil
    }

    private mutating func insert(scene: String, folder: String?, at index: Int?) {
        if let folder {
            withFolder(folder) {
                var scenes = $0.scenes
                scenes.insert(scene, at: Swift.min(index ?? scenes.count, scenes.count))
                $0.setScenes(scenes)
            }
        } else {
            insert(.scene(scene), at: Swift.min(index ?? count, count))
        }
    }

    /// Moves a scene into a folder (nil for the top level), to sit before the row now at
    /// `index` there, or at the end.
    mutating func move(scene: String, toFolder folder: String?, at index: Int? = nil) {
        if let folder, folderIndex(folder) == nil { return }
        guard let from = remove(scene: scene) else { return }
        var index = index
        if let i = index, from.folder == folder, from.index < i { index = i - 1 }
        insert(scene: scene, folder: folder, at: index)
    }

    /// Moves a folder to sit before the top-level row now at `index`.
    mutating func move(folder: String, to index: Int) {
        guard let from = folderIndex(folder) else { return }
        let item = remove(at: from)
        insert(item, at: Swift.min(from < index ? index - 1 : index, count))
    }

    /// Lists a new scene straight after another, in its folder: a duplicate after its original.
    mutating func add(scene: String, after other: String) {
        if let i = firstIndex(of: .scene(other)) {
            insert(.scene(scene), at: i + 1)
            return
        }
        guard let folder = folder(containing: other), let i = folder.scenes.firstIndex(of: other) else { return }
        insert(scene: scene, folder: folder.name, at: i + 1)
    }

    mutating func rename(scene old: String, to new: String) {
        self = map { item in
            switch item {
            case .scene(let slug): return .scene(slug == old ? new : slug)
            case .folder(var folder):
                folder.rename(scene: old, to: new)
                return .folder(folder)
            }
        }
    }

    /// Sets the transition after a folder's entry `index`, into the next one.
    mutating func setTransition(folder: String, _ index: Int, _ spec: TransitionSpec) {
        withFolder(folder) { $0.setTransition(index, spec) }
    }

    /// A folder name no other folder has: `name`, or `name 2`…
    func uniqueFolderName(_ name: String, except: String? = nil) -> String {
        let taken = Set(folders).subtracting([except].compactMap { $0 })
        var candidate = name, n = 2
        while taken.contains(candidate) { candidate = "\(name) \(n)"; n += 1 }
        return candidate
    }

    /// New folders go at the top, where they can be seen.
    mutating func addFolder(_ name: String) {
        insert(.folder(SidebarFolder(name: name, open: true)), at: 0)
    }

    mutating func renameFolder(_ old: String, to new: String) {
        withFolder(old) { $0.name = new }
    }

    mutating func setFolder(_ name: String, open: Bool) {
        withFolder(name) { $0.open = open }
    }

    /// Removes a folder, and with it its transitions. Its scenes stay, in the list where the
    /// folder was.
    mutating func removeFolder(_ name: String) {
        guard let i = folderIndex(name), case .folder(let folder) = self[i] else { return }
        replaceSubrange(i...i, with: folder.scenes.map(SidebarItem.scene))
    }
}

/// The Scenes list's order and folders, and the folder being renamed. Main thread only.
@Observable
final class SidebarState {
    fileprivate(set) var file = SidebarFile()
    /// The folder being renamed.
    var renamingFolder: String?

    /// Brings the list in line with the scene files on disk and returns them in its order.
    func ordered(_ urls: [URL]) -> [URL] {
        let bySlug = Dictionary(uniqueKeysWithValues: urls.map { ($0.deletingPathExtension().lastPathComponent, $0) })
        var items = file.scenes
        items.reconcile(urls.map { $0.deletingPathExtension().lastPathComponent })
        if items != file.scenes { file.scenes = items }
        return items.scenes.compactMap { bySlug[$0] }
    }
}

extension Engine {
    /// Reads `Sidebar.json`. If it's invalid the error shows and the list stays as it was.
    func loadSidebar() {
        let url = store.sidebarURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            sidebar.file = SidebarFile()
            errors[url.lastPathComponent] = nil
            return
        }
        do {
            sidebar.file = try SidebarFile.load(url)
            errors[url.lastPathComponent] = nil
        } catch {
            errors[url.lastPathComponent] = error is DecodingError ? "JSON invalid: \(error)" : error.localizedDescription
        }
    }

    /// Changes the list's order, folders or transitions, saves it and shows it.
    func editSidebar(_ change: (inout [SidebarItem]) -> Void) {
        var items = sidebar.file.scenes
        change(&items)
        guard items != sidebar.file.scenes else { return }
        sidebar.file.scenes = items
        let url = store.sidebarURL
        do {
            try sidebar.file.write(to: url)
            store.markSeen(url)
            errors[url.lastPathComponent] = nil
        } catch {
            errors[url.lastPathComponent] = "save failed: \(error.localizedDescription)"
        }
        refreshSceneList()
    }

    /// Adds a folder to the list and starts naming it.
    func createSidebarFolder() {
        let name = sidebar.file.scenes.uniqueFolderName("New Folder")
        editSidebar { $0.addFolder(name) }
        sidebar.renamingFolder = name
    }

    func renameSidebarFolder(_ folder: String, to newName: String) {
        sidebar.renamingFolder = nil
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != folder else { return }
        editSidebar { $0.renameFolder(folder, to: $0.uniqueFolderName(name, except: folder)) }
    }
}
