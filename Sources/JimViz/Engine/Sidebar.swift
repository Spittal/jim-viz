import Foundation
import Observation

/// A row of a sidebar list: a scene or playlist, by its file name without `.json`, or a folder
/// of them. Folders only organise the list: they hold files, not other folders, and the files
/// on disk stay where they are.
enum SidebarItem: Codable, Equatable, Identifiable {
    case file(String)
    case folder(SidebarFolder)

    var id: String {
        switch self {
        case .file(let slug): return "file:\(slug)"
        case .folder(let folder): return "folder:\(folder.name)"
        }
    }

    /// In JSON a file is its name and a folder an object.
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let slug = try? c.decode(String.self) { self = .file(slug) } else { self = .folder(try c.decode(SidebarFolder.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .file(let slug): try c.encode(slug)
        case .folder(let folder): try c.encode(folder)
        }
    }
}

struct SidebarFolder: Codable, Equatable {
    var name: String
    /// Unfolded in the list.
    var open: Bool
    var items: [String]
}

/// The order and folders of the Scenes and Playlists lists, in `<library>/Sidebar.json`.
/// Without the file, both lists are flat and in name order.
struct SidebarFile: Codable, Equatable {
    var scenes: [SidebarItem] = []
    var playlists: [SidebarItem] = []

    subscript(tab: SidebarTab) -> [SidebarItem] {
        get { tab == .scenes ? scenes : playlists }
        set { if tab == .scenes { scenes = newValue } else { playlists = newValue } }
    }

    struct Invalid: LocalizedError {
        let errorDescription: String?
    }

    /// Strict: a file listed twice, or two folders with one name, is an error.
    static func load(_ url: URL) throws -> SidebarFile {
        let file = try JSONDecoder().decode(SidebarFile.self, from: Data(contentsOf: url))
        for (label, items) in [("scenes", file.scenes), ("playlists", file.playlists)] {
            guard Set(items.files).count == items.files.count else { throw Invalid(errorDescription: "invalid shape: \(label) lists a file twice") }
            guard Set(items.folders).count == items.folders.count, !items.folders.contains("") else {
                throw Invalid(errorDescription: "invalid shape: \(label) folders need names of their own")
            }
        }
        return file
    }

    func write(to url: URL) throws {
        try JSONEncoder.pretty.encode(self).write(to: url, options: .atomic)
    }
}

extension [SidebarItem] {
    /// Every file, top to bottom, folders' files included.
    var files: [String] {
        flatMap { item -> [String] in
            switch item {
            case .file(let slug): return [slug]
            case .folder(let folder): return folder.items
            }
        }
    }

    var folders: [String] {
        compactMap { if case .folder(let folder) = $0 { folder.name } else { nil } }
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
            case .file(let slug): return have.contains(slug) ? item : nil
            case .folder(var folder):
                folder.items.removeAll { !have.contains($0) }
                return .folder(folder)
            }
        }
        let listed = Set(files)
        append(contentsOf: present.filter { !listed.contains($0) }.map(SidebarItem.file))
    }

    /// Takes a file out of the top level or its folder, and says where it was.
    private mutating func remove(file: String) -> (folder: String?, index: Int)? {
        if let i = firstIndex(of: .file(file)) {
            remove(at: i)
            return (nil, i)
        }
        for case .folder(let folder) in self {
            guard let i = folder.items.firstIndex(of: file) else { continue }
            withFolder(folder.name) { $0.items.remove(at: i) }
            return (folder.name, i)
        }
        return nil
    }

    private mutating func insert(file: String, folder: String?, at index: Int?) {
        if let folder {
            withFolder(folder) { $0.items.insert(file, at: Swift.min(index ?? $0.items.count, $0.items.count)) }
        } else {
            insert(.file(file), at: Swift.min(index ?? count, count))
        }
    }

    /// Moves a file into a folder (nil for the top level), to sit before the row now at
    /// `index` there, or at the end.
    mutating func move(file: String, toFolder folder: String?, at index: Int? = nil) {
        if let folder, folderIndex(folder) == nil { return }
        guard let from = remove(file: file) else { return }
        var index = index
        if let i = index, from.folder == folder, from.index < i { index = i - 1 }
        insert(file: file, folder: folder, at: index)
    }

    /// Moves a folder to sit before the top-level row now at `index`.
    mutating func move(folder: String, to index: Int) {
        guard let from = folderIndex(folder) else { return }
        let item = remove(at: from)
        insert(item, at: Swift.min(from < index ? index - 1 : index, count))
    }

    /// Lists a new file straight after another, in its folder: a duplicate after its original.
    mutating func add(file: String, after other: String) {
        if let i = firstIndex(of: .file(other)) {
            insert(.file(file), at: i + 1)
            return
        }
        for case .folder(let folder) in self {
            guard let i = folder.items.firstIndex(of: other) else { continue }
            withFolder(folder.name) { $0.items.insert(file, at: i + 1) }
            return
        }
    }

    mutating func rename(file old: String, to new: String) {
        self = map { item in
            switch item {
            case .file(let slug): return .file(slug == old ? new : slug)
            case .folder(var folder):
                folder.items = folder.items.map { $0 == old ? new : $0 }
                return .folder(folder)
            }
        }
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
        insert(.folder(SidebarFolder(name: name, open: true, items: [])), at: 0)
    }

    mutating func renameFolder(_ old: String, to new: String) {
        withFolder(old) { $0.name = new }
    }

    mutating func setFolder(_ name: String, open: Bool) {
        withFolder(name) { $0.open = open }
    }

    /// Removes a folder. Its files stay, in the list where the folder was.
    mutating func removeFolder(_ name: String) {
        guard let i = folderIndex(name), case .folder(let folder) = self[i] else { return }
        replaceSubrange(i...i, with: folder.items.map(SidebarItem.file))
    }
}

/// The sidebar lists' order and folders, and the folder being renamed. Main thread only.
@Observable
final class SidebarState {
    fileprivate(set) var file = SidebarFile()
    /// The folder being renamed, in the list on show.
    var renamingFolder: String?

    /// Brings a list in line with the files on disk and returns them in its order.
    func ordered(_ tab: SidebarTab, _ urls: [URL]) -> [URL] {
        let bySlug = Dictionary(uniqueKeysWithValues: urls.map { ($0.deletingPathExtension().lastPathComponent, $0) })
        var items = file[tab]
        items.reconcile(urls.map { $0.deletingPathExtension().lastPathComponent })
        if items != file[tab] { file[tab] = items }
        return items.files.compactMap { bySlug[$0] }
    }
}

extension Engine {
    /// Reads `Sidebar.json`. If it's invalid the error shows and the lists stay as they were.
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

    /// Changes a list's order or folders, saves it and shows it.
    func editSidebar(_ tab: SidebarTab, _ change: (inout [SidebarItem]) -> Void) {
        var items = sidebar.file[tab]
        change(&items)
        guard items != sidebar.file[tab] else { return }
        sidebar.file[tab] = items
        let url = store.sidebarURL
        do {
            try sidebar.file.write(to: url)
            store.markSeen(url)
            errors[url.lastPathComponent] = nil
        } catch {
            errors[url.lastPathComponent] = "save failed: \(error.localizedDescription)"
        }
        if tab == .scenes { refreshSceneList() } else { refreshPlaylists() }
    }

    /// Adds a folder to a list and starts naming it.
    func createSidebarFolder(_ tab: SidebarTab) {
        let name = sidebar.file[tab].uniqueFolderName("New Folder")
        editSidebar(tab) { $0.addFolder(name) }
        sidebar.renamingFolder = name
    }

    func renameSidebarFolder(_ tab: SidebarTab, _ folder: String, to newName: String) {
        sidebar.renamingFolder = nil
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != folder else { return }
        editSidebar(tab) { $0.renameFolder(folder, to: $0.uniqueFolderName(name, except: folder)) }
    }
}
