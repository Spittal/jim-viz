import Foundation
import Observation

/// The bottom bar's state. The playlist it shows is the sidebar folder holding the scene
/// playing (`Engine.playlist`). Its Previous and Next map to MIDI in MIDI map mode, as the app
/// targets `app.previous` and `app.next` (`MIDIMap`). Main thread only.
@Observable
final class PlaylistState {
    /// The bottom bar unfolded to show the playlist's scenes. Its header, with the transport,
    /// always shows.
    var expanded: Bool {
        didSet { defaults.set(expanded, forKey: "playlist.expanded") }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        expanded = defaults.bool(forKey: "playlist.expanded")
    }
}

extension Engine {
    // MARK: The playlist

    /// The playlist in the bottom bar: the folder holding the scene playing, if it's in one.
    var playlist: SidebarFolder? {
        playingURL.flatMap { sidebar.file.scenes.folder(containing: $0.deletingPathExtension().lastPathComponent) }
    }

    /// Where the scene playing is in the playlist.
    var playlistPosition: Int? {
        guard let playlist, let slug = playingURL?.deletingPathExtension().lastPathComponent else { return nil }
        return playlist.scenes.firstIndex(of: slug)
    }

    /// True when the scene playing is in a playlist; ⌘[ and ⌘] then step it.
    var playlistActive: Bool { playlist != nil }

    /// A scene's file in `<library>/Scenes`, by its file name.
    func sceneURL(_ slug: String) -> URL? {
        sceneURLs.first { $0.deletingPathExtension().lastPathComponent == slug }
    }

    /// Sets the transition after entry `index` of the playlist, into the next one.
    func setPlaylistTransition(_ index: Int, _ spec: TransitionSpec) {
        guard let playlist else { return }
        var s = spec
        s.duration = min(max(s.duration, TransitionSpec.durationRange.lowerBound), TransitionSpec.durationRange.upperBound)
        editSidebar { $0.setTransition(folder: playlist.name, index, s) }
    }

    // MARK: Playing

    /// Shows entry `index`, blending in with the transition on the link before it.
    func playPlaylistEntry(_ index: Int) {
        guard let playlist, playlist.entries.indices.contains(index) else { return }
        play(playlist.entries[index].scene, transition: playlist.transition(into: index))
    }

    /// Steps the playlist, looping at either end. Each step uses the transition on the link it
    /// crosses, whichever way it goes.
    func stepPlaylist(_ delta: Int) {
        guard let playlist, let p = playlistPosition else { return }
        let n = playlist.entries.count
        let target = ((p + delta) % n + n) % n
        // Forwards, the link into the target; backwards, the link out of it.
        let spec = delta > 0 ? playlist.transition(into: target) : playlist.entries[target].transition
        play(playlist.entries[target].scene, transition: spec)
    }

    private func play(_ scene: String, transition: TransitionSpec) {
        guard let url = sceneURL(scene) else {
            errors["playlist"] = "scene “\(scene)” not found in the library’s Scenes folder"
            return
        }
        errors["playlist"] = nil
        selectDevice(nil)
        load(url, transition: transition)
    }
}
