import Foundation
import simd

/// Maps musical keys (e.g. "Am", "8A", "F#m", "11B") to Camelot wheel positions
/// and harmonic color palettes for the visualizer.
enum CamelotKey {
    struct KeyInfo: Hashable {
        let standard: String // "Am"
        let camelot: String  // "8A"
        let number: Int      // 1...12
        let isMinor: Bool    // true for A, false for B
        let hue: Float       // 0...1 on the color wheel
    }

    /// Complete mapping table for all 24 musical keys.
    private static let keyTable: [String: KeyInfo] = {
        var table: [String: KeyInfo] = [:]

        // (Standard, Camelot number, isMinor, hue)
        let pairs: [(String, Int, Bool, Float)] = [
            ("Abm", 1, true, 0.50),   ("G#m", 1, true, 0.50),   ("B", 1, false, 0.50),
            ("Ebm", 2, true, 0.58),   ("D#m", 2, true, 0.58),   ("F#", 2, false, 0.58),  ("Gb", 2, false, 0.58),
            ("Bbm", 3, true, 0.67),   ("A#m", 3, true, 0.67),   ("Db", 3, false, 0.67),  ("C#", 3, false, 0.67),
            ("Fm", 4, true, 0.75),    ("Ab", 4, false, 0.75),   ("G#", 4, false, 0.75),
            ("Cm", 5, true, 0.83),    ("Eb", 5, false, 0.83),   ("D#", 5, false, 0.83),
            ("Gm", 6, true, 0.92),    ("Bb", 6, false, 0.92),   ("A#", 6, false, 0.92),
            ("Dm", 7, true, 0.00),    ("F", 7, false, 0.00),
            ("Am", 8, true, 0.08),    ("C", 8, false, 0.08),
            ("Em", 9, true, 0.17),    ("G", 9, false, 0.17),
            ("Bm", 10, true, 0.25),   ("D", 10, false, 0.25),
            ("F#m", 11, true, 0.33),  ("Gbm", 11, true, 0.33),  ("A", 11, false, 0.33),
            ("Dbm", 12, true, 0.42),  ("C#m", 12, true, 0.42),  ("E", 12, false, 0.42),
        ]

        for (name, num, minor, hue) in pairs {
            let camelot = "\(num)\(minor ? "A" : "B")"
            let info = KeyInfo(standard: name, camelot: camelot, number: num, isMinor: minor, hue: hue)
            table[name.lowercased()] = info
            table[camelot.lowercased()] = info
        }
        return table
    }()

    static func parse(_ raw: String) -> KeyInfo? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return keyTable[clean]
    }

    /// Converts HSV (all 0...1) to linear RGB.
    static func hsv2rgb(h: Float, s: Float, v: Float) -> SIMD3<Float> {
        let c = v * s
        let x = c * (1 - abs(fmod(h * 6, 2) - 1))
        let m = v - c
        let (r, g, b): (Float, Float, Float)
        switch Int(floor(h * 6)) % 6 {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return SIMD3<Float>(r + m, g + m, b + m)
    }

    /// Generates a rich 5-color dark-to-light visual palette based on the track's musical key.
    static func palette(for key: KeyInfo) -> [SIMD3<Float>] {
        let baseHue = key.hue
        let complementHue = fmod(baseHue + 0.5, 1.0)
        let neighborHue = fmod(baseHue + (key.isMinor ? 0.08 : -0.08) + 1.0, 1.0)

        // 1. Deep dark background
        let bg = hsv2rgb(h: baseHue, s: 0.85, v: 0.06)
        // 2. Saturated mid-dark accent
        let midDark = hsv2rgb(h: complementHue, s: 0.90, v: 0.35)
        // 3. Primary key color
        let primary = hsv2rgb(h: baseHue, s: 0.95, v: 0.75)
        // 4. Harmonic neighbor tint
        let neighbor = hsv2rgb(h: neighborHue, s: 0.70, v: 0.95)
        // 5. Bright highlight
        let highlight = hsv2rgb(h: baseHue, s: 0.20, v: 1.0)

        return [bg, midDark, primary, neighbor, highlight]
    }
}
