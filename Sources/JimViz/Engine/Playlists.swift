import Foundation
import Observation

/// What a playlist's transport buttons do. Each can be bound to a MIDI control.
enum PlaylistAction: String, CaseIterable {
    case previous, next

    var label: String { self == .next ? "Next Scene" : "Previous Scene" }
}

/// The left sidebar's tabs.
enum SidebarTab: String, CaseIterable {
    case scenes, playlists

    var label: String { self == .scenes ? "Scenes" : "Playlists" }
}

/// Playlists in `<library>/Playlists`, the one open in the bottom bar, and the bar's MIDI
/// bindings. Main thread only; the render thread never reads it.
@Observable
final class PlaylistState {
    var tab: SidebarTab = .scenes
    private(set) var urls: [URL] = []
    /// Display names from each file's `name`, falling back to the file name.
    private(set) var names: [URL: String] = [:]
    /// The playlist in the bottom bar: the first one unless another is picked. Nil only when
    /// there are none.
    fileprivate(set) var selectedURL: URL?
    fileprivate(set) var file: PlaylistFile?
    /// The entry last played from the open playlist.
    fileprivate(set) var position: Int?
    var renaming: URL?
    var pendingDeletion: URL?

    /// While on, clicking Previous or Next picks it to learn a MIDI control instead of stepping.
    var mapMode = false {
        didSet { if !mapMode { learning = nil } }
    }
    /// The bottom bar unfolded to show the playlist's scenes. Its header, with the transport,
    /// always shows.
    var expanded: Bool {
        didSet { defaults.set(expanded, forKey: "playlist.expanded") }
    }
    /// The button waiting for a MIDI control.
    var learning: PlaylistAction?
    /// The MIDI control bound to each button, for every playlist. Kept on this Mac, like
    /// window layout, since it belongs to the controller rather than to a set.
    private(set) var bindings: [PlaylistAction: MIDIControl] = [:]
    /// Per binding: whether its control has dropped low enough to fire again, as for trigger inputs.
    @ObservationIgnored fileprivate var armed: [PlaylistAction: Bool] = [:]

    /// Where bindings are kept: the app's defaults, or a scratch suite for the self-check.
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        expanded = defaults.bool(forKey: "playlist.expanded")
        for action in PlaylistAction.allCases {
            if let key = defaults.string(forKey: Self.defaultsKey(action)), let control = MIDIControl(key: key) {
                bindings[action] = control
            }
        }
    }

    private static func defaultsKey(_ action: PlaylistAction) -> String { "playlist.midi.\(action.rawValue)" }

    fileprivate func bind(_ action: PlaylistAction, _ control: MIDIControl?) {
        bindings[action] = control
        armed[action] = nil
        if let control {
            defaults.set(control.key, forKey: Self.defaultsKey(action))
        } else {
            defaults.removeObject(forKey: Self.defaultsKey(action))
        }
    }

    fileprivate func setList(_ list: [URL], names newNames: [URL: String]) {
        if list != urls { urls = list }
        if newNames != names { names = newNames }
    }

    func name(_ url: URL) -> String { names[url] ?? url.deletingPathExtension().lastPathComponent }
}

extension Engine {
    // MARK: Playlist files

    func refreshPlaylists() {
        let list = store.playlistURLs()
        struct Named: Decodable { let name: String? }
        var names: [URL: String] = [:]
        for url in list {
            let decoded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Named.self, from: $0) }
            names[url] = decoded?.name ?? url.deletingPathExtension().lastPathComponent
        }
        playlists.setList(list, names: names)
        if let url = playlists.selectedURL, list.contains(url) {
            reloadSelectedPlaylist()
        } else {
            selectPlaylist(list.first)
        }
    }

    /// Opens a playlist in the bottom bar (nil when there are none). Starts on the entry
    /// showing now, if the scene on screen is in it.
    func selectPlaylist(_ url: URL?) {
        guard url != playlists.selectedURL else { return }
        playlists.selectedURL = url
        playlists.file = nil
        playlists.position = nil
        playlists.mapMode = false
        if url != nil {
            reloadSelectedPlaylist()
            let slug = currentURL?.deletingPathExtension().lastPathComponent
            playlists.position = playlists.file?.entries.firstIndex { $0.scene == slug }
        }
        activateHardware()
    }

    private func reloadSelectedPlaylist() {
        guard let url = playlists.selectedURL else { return }
        do {
            let file = try PlaylistFile.load(url)
            errors[url.lastPathComponent] = nil
            if file != playlists.file { playlists.file = file }
            if let p = playlists.position, p >= file.entries.count { playlists.position = nil }
        } catch {
            errors[url.lastPathComponent] = describePlaylistError(error)
            playlists.file = nil
        }
    }

    private func describePlaylistError(_ error: Error) -> String {
        if error is DecodingError { return "JSON invalid: \(error)" }
        return error.localizedDescription
    }

    func createPlaylist() {
        let url = uniquePlaylistURL("New Playlist")
        let file = PlaylistFile(name: url.name, entries: [])
        writePlaylist(file, to: url.url)
        refreshPlaylists()
        selectPlaylist(url.url)
        playlists.renaming = url.url
    }

    func duplicatePlaylist(_ url: URL) {
        guard var file = try? PlaylistFile.load(url) else { errors["playlist"] = "could not read \(url.lastPathComponent)"; return }
        let dest = uniquePlaylistURL("\(file.name) Copy")
        file.name = dest.name
        writePlaylist(file, to: dest.url)
        refreshPlaylists()
        selectPlaylist(dest.url)
    }

    func renamePlaylist(_ url: URL, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        playlists.renaming = nil
        guard !name.isEmpty, name != playlists.name(url) else { return }
        guard var file = try? PlaylistFile.load(url) else { errors["playlist"] = "could not read \(url.lastPathComponent)"; return }
        let dest = uniquePlaylistURL(name, except: url)
        file.name = name
        writePlaylist(file, to: dest.url)
        if dest.url.standardizedFileURL != url.standardizedFileURL { try? FileManager.default.removeItem(at: url) }
        let wasSelected = playlists.selectedURL == url
        let position = playlists.position
        if wasSelected { playlists.selectedURL = dest.url; playlists.file = file; playlists.position = position }
        refreshPlaylists()
        info = "Renamed playlist to \(name)"
    }

    func deletePlaylist(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            errors[url.lastPathComponent] = nil
            refreshPlaylists()
            info = "Deleted playlist \(playlists.name(url))"
        } catch {
            errors["playlist"] = "delete failed: \(error.localizedDescription)"
        }
    }

    /// A file name for a playlist called `name` (or `name 2`…) that no other playlist has.
    private func uniquePlaylistURL(_ name: String, except: URL? = nil) -> (url: URL, name: String) {
        let taken = Set(store.playlistURLs().filter { $0 != except }.map { $0.deletingPathExtension().lastPathComponent })
        var candidate = name, n = 2
        while taken.contains(slugify(candidate)) { candidate = "\(name) \(n)"; n += 1 }
        return (store.playlistsDir.appendingPathComponent("\(slugify(candidate)).json"), candidate)
    }

    private func writePlaylist(_ file: PlaylistFile, to url: URL) {
        do {
            try file.write(to: url)
            store.markSeen(url)
            errors["playlist"] = nil
        } catch {
            errors["playlist"] = "save failed: \(error.localizedDescription)"
        }
    }

    // MARK: Editing the open playlist

    /// Changes the open playlist and saves it straight away.
    private func editPlaylist(_ change: (inout PlaylistFile) -> Void) {
        guard let url = playlists.selectedURL, var file = playlists.file else { return }
        change(&file)
        playlists.file = file
        writePlaylist(file, to: url)
    }

    /// Inserts a scene (by file name) before entry `index`, or at the end. Its transition into
    /// the next entry starts as the default crossfade.
    func insertPlaylistScene(_ scene: String, at index: Int? = nil) {
        editPlaylist { file in
            let i = min(index ?? file.entries.count, file.entries.count)
            file.entries.insert(PlaylistEntry(scene: scene, transition: .default), at: i)
            if let p = playlists.position, p >= i { playlists.position = p + 1 }
        }
    }

    /// Moves entry `from` so it lands before the entry now at `to` (or at the end).
    /// Its transition goes with it.
    func movePlaylistEntry(from: Int, to: Int) {
        editPlaylist { file in
            guard file.entries.indices.contains(from) else { return }
            let dest = min(to > from ? to - 1 : to, file.entries.count - 1)
            guard dest != from else { return }
            let entry = file.entries.remove(at: from)
            file.entries.insert(entry, at: dest)
            if playlists.position == from { playlists.position = dest }
            else if let p = playlists.position {
                if from < p && dest >= p { playlists.position = p - 1 }
                else if from > p && dest <= p { playlists.position = p + 1 }
            }
        }
    }

    func removePlaylistEntry(_ index: Int) {
        editPlaylist { file in
            guard file.entries.indices.contains(index) else { return }
            file.entries.remove(at: index)
            if playlists.position == index { playlists.position = nil }
            else if let p = playlists.position, p > index { playlists.position = p - 1 }
        }
    }

    /// Sets the transition after entry `index`, into the next one.
    func setPlaylistTransition(_ index: Int, _ spec: TransitionSpec) {
        editPlaylist { file in
            guard file.entries.indices.contains(index) else { return }
            var s = spec
            s.duration = min(max(s.duration, TransitionSpec.durationRange.lowerBound), TransitionSpec.durationRange.upperBound)
            file.entries[index].transition = s
        }
    }

    /// Points playlists at a scene's new file name after a rename.
    func renameSceneInPlaylists(from old: String, to new: String) {
        guard old != new else { return }
        for url in store.playlistURLs() {
            guard var file = try? PlaylistFile.load(url), file.entries.contains(where: { $0.scene == old }) else { continue }
            for i in file.entries.indices where file.entries[i].scene == old { file.entries[i].scene = new }
            writePlaylist(file, to: url)
            if url == playlists.selectedURL { playlists.file = file }
        }
    }

    // MARK: Playing

    /// A playlist entry's scene file, if it's in `<library>/Scenes`.
    func playlistSceneURL(_ scene: String) -> URL? {
        sceneURLs.first { $0.deletingPathExtension().lastPathComponent == scene }
    }

    /// True when the open playlist has an entry to step to; ⌘[ and ⌘] then step it.
    var playlistActive: Bool { !(playlists.file?.entries.isEmpty ?? true) }

    /// Shows entry `index`, blending in with the transition on the link before it.
    func playPlaylistEntry(_ index: Int) {
        guard let file = playlists.file, file.entries.indices.contains(index) else { return }
        play(index, transition: file.transition(into: index))
    }

    /// Steps the open playlist, looping at either end. Each step uses the transition on the
    /// link it crosses, whichever way it goes.
    func stepPlaylist(_ delta: Int) {
        guard let file = playlists.file, !file.entries.isEmpty else { return }
        let n = file.entries.count
        let target: Int
        if let p = playlists.position {
            target = ((p + delta) % n + n) % n
        } else {
            target = delta > 0 ? 0 : n - 1
        }
        // Forwards, the link into the target; backwards, the link out of it.
        let spec = delta > 0 ? file.transition(into: target) : file.entries[target].transition
        play(target, transition: spec)
    }

    private func play(_ index: Int, transition: TransitionSpec) {
        guard let file = playlists.file else { return }
        playlists.position = index
        let scene = file.entries[index].scene
        guard let url = playlistSceneURL(scene) else {
            errors["playlist"] = "\(file.name): scene “\(scene)” not found in the library’s Scenes folder"
            return
        }
        errors["playlist"] = nil
        selectDevice(nil)
        load(url, transition: transition)
    }

    /// Keeps the open playlist's highlight on the scene being loaded: the entry already
    /// playing if it's that scene, else its first entry, or none if it isn't in the playlist.
    func followPlaylist(_ url: URL) {
        guard let file = playlists.file else { return }
        let slug = url.deletingPathExtension().lastPathComponent
        if let p = playlists.position, file.entries.indices.contains(p), file.entries[p].scene == slug { return }
        playlists.position = file.entries.firstIndex { $0.scene == slug }
    }

    // MARK: MIDI

    /// Toggles a button waiting for a MIDI control.
    func learnPlaylistMIDI(_ action: PlaylistAction?) {
        playlists.learning = action
        activateHardware()
    }

    func clearPlaylistMIDI(_ action: PlaylistAction) {
        playlists.bind(action, nil)
        activateHardware()
    }

    /// True while the bar wants MIDI: a playlist is open and a button is bound or learning.
    var playlistWantsMIDI: Bool {
        playlists.selectedURL != nil && (!playlists.bindings.isEmpty || playlists.learning != nil)
    }

    /// Takes a MIDI message for the bar's buttons. A learning button takes the control and
    /// the message stops here; a bound one fires when its control rises past ½, re-arming
    /// below ¼, like a trigger input.
    /// Returns true when the message was used to learn.
    func handlePlaylistMIDI(_ msg: MIDIMessage) -> Bool {
        guard playlists.selectedURL != nil, let control = MIDIControl(msg) else { return false }
        let value = MIDIControl.value(msg)
        if let action = playlists.learning {
            guard value >= 0.5 else { return true }
            for other in PlaylistAction.allCases where other != action && playlists.bindings[other] == control {
                playlists.bind(other, nil)
            }
            playlists.bind(action, control)
            playlists.armed[action] = false
            playlists.learning = nil
            info = "\(action.label) ← \(control.label)"
            return true
        }
        for action in PlaylistAction.allCases where playlists.bindings[action] == control {
            let armed = playlists.armed[action] ?? true
            if armed && value >= 0.5 {
                playlists.armed[action] = false
                stepPlaylist(action == .next ? 1 : -1)
            } else if value < 0.25 {
                playlists.armed[action] = true
            }
        }
        return false
    }
}
