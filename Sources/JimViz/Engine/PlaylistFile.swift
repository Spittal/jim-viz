import Foundation

/// How one scene hands over to the next. Only a crossfade for now; new types are new cases
/// here and in `Renderer.encodeTransition`.
enum TransitionType: String, Codable, CaseIterable {
    case crossfade

    var label: String {
        switch self {
        case .crossfade: return "Crossfade"
        }
    }
}

struct TransitionSpec: Codable, Equatable {
    var type: TransitionType
    /// Seconds.
    var duration: Double

    static let `default` = TransitionSpec(type: .crossfade, duration: 0.3)
    static let durationRange: ClosedRange<Double> = 0...10

    /// "Crossfade 300 ms".
    var label: String { "\(type.label) \(Int((duration * 1000).rounded())) ms" }
}

/// A scene in a playlist, and the transition into the entry after it. The last entry's
/// transition wraps around to the first, so the playlist loops.
struct PlaylistEntry: Codable, Equatable {
    /// The scene's file name in `Content/Scenes`, without `.json`.
    var scene: String
    var transition: TransitionSpec
}

/// A sequence of scenes played left to right, in `Content/Playlists/<slug>.json`.
struct PlaylistFile: Codable, Equatable {
    var name: String
    var entries: [PlaylistEntry]

    static func load(_ url: URL) throws -> PlaylistFile {
        try JSONDecoder().decode(PlaylistFile.self, from: Data(contentsOf: url))
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.pretty.encode(self).write(to: url, options: .atomic)
    }

    /// The transition into entry `index`: the one on the link before it, wrapping around.
    func transition(into index: Int) -> TransitionSpec {
        entries[(index - 1 + entries.count) % entries.count].transition
    }
}
