import Foundation
import Observation

/// What a playlist's transport buttons do. Each can be bound to a MIDI control.
enum PlaylistAction: String, CaseIterable {
    case previous, next

    var label: String { self == .next ? "Next Scene" : "Previous Scene" }
}

/// The bottom bar's state and its MIDI bindings. The playlist it shows is the sidebar folder
/// holding the scene playing (`Engine.playlist`). Main thread only; the render thread never
/// reads it.
@Observable
final class PlaylistState {
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

    /// True while the bar wants MIDI: a button is bound or learning.
    var playlistWantsMIDI: Bool {
        !playlists.bindings.isEmpty || playlists.learning != nil
    }

    /// Takes a MIDI message for the bar's buttons. A learning button takes the control and
    /// the message stops here; a bound one steps the playlist when its control rises past ½,
    /// re-arming below ¼, like a trigger input.
    /// Returns true when the message was used to learn.
    func handlePlaylistMIDI(_ msg: MIDIMessage) -> Bool {
        guard let control = MIDIControl(msg) else { return false }
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
