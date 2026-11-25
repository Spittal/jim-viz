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

/// A scene in a playlist (a sidebar folder), and the transition into the entry after it. The
/// last entry's transition wraps around to the first, so the playlist loops.
struct PlaylistEntry: Codable, Equatable {
    /// The scene's file name in `<library>/Scenes`, without `.json`.
    var scene: String
    var transition: TransitionSpec
}
