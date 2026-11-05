import SwiftUI

/// Colors for the Ableton-inspired working area. Window chrome stays native.
enum Theme {
    static let chainBackground = Color(white: 0.13)
    static let device = Color(white: 0.20)
    static let deviceHeader = Color(white: 0.25)
    /// Header and outline of the selected device.
    static let deviceHeaderSelected = Color(white: 0.36)
    static let selection = Color(white: 0.72)
    static let deviceBorder = Color(white: 0.08)
    static let deviceOff = Color(white: 0.16)
    static let text = Color(white: 0.82)
    static let textDim = Color(white: 0.55)
    static let knobTrack = Color(white: 0.32)
    static let accent = Color(red: 1.0, green: 0.62, blue: 0.18)
    static let modulation = Color(red: 0.25, green: 0.80, blue: 0.95)
    /// MIDI mapping, after Ableton's MIDI map blue.
    static let midi = Color(red: 0.45, green: 0.38, blue: 0.98)
    static let beatOn = Color(red: 0.55, green: 0.95, blue: 0.35)
    static let beatDownbeat = Color(red: 1.0, green: 0.62, blue: 0.18)
    static let error = Color(red: 1.0, green: 0.38, blue: 0.35)
    static let previewBackground = Color(white: 0.06)

    static let labelFont = Font.system(size: 9, weight: .medium)
    static let valueFont = Font.system(size: 9).monospacedDigit()
    static let titleFont = Font.system(size: 11, weight: .semibold)
}
