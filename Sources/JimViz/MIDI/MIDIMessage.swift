import CoreMIDI
import Foundation

enum MIDICommand: UInt8, CaseIterable {
    case noteOff = 0x80
    case noteOn = 0x90
    case polyAftertouch = 0xA0
    case controlChange = 0xB0
    case programChange = 0xC0
    case channelAftertouch = 0xD0
    case pitchBend = 0xE0

    var name: String {
        switch self {
        case .noteOff: return "Note Off"
        case .noteOn: return "Note On"
        case .polyAftertouch: return "Poly Aftertouch"
        case .controlChange: return "CC"
        case .programChange: return "Program Change"
        case .channelAftertouch: return "Channel Aftertouch"
        case .pitchBend: return "Pitch Bend"
        }
    }
}

/// A parsed standard MIDI 1.0 channel message.
struct MIDIMessage: Hashable {
    /// 1-based MIDI channel (1...16).
    let channel: Int
    let command: MIDICommand
    /// CC number (0...127) or Note number (0...127).
    let data1: Int
    /// CC value (0...127) or Velocity (0...127).
    let data2: Int
    /// Exact receive timestamp.
    let timestamp: MIDITimeStamp
    /// Name of the device it came from, when known.
    var device: String? = nil

    /// Normalized 0...1 value for parameter modulation.
    var normalizedValue: Float {
        switch command {
        case .pitchBend:
            // 14-bit pitch bend: data1 = LSB, data2 = MSB
            let bend = (data2 << 7) | data1
            return Float(bend) / 16383.0
        case .noteOff:
            return 0
        default:
            return Float(data2) / 127.0
        }
    }

    /// Binding key for exact channel match (e.g. `cc:31:7` or `note:11:1`).
    var exactKey: String {
        switch command {
        case .controlChange: return "cc:\(data1):\(channel)"
        case .noteOn, .noteOff: return "note:\(data1):\(channel)"
        case .pitchBend: return "pitchbend:\(channel)"
        default: return "other:\(data1):\(channel)"
        }
    }

    /// Binding key matching any channel (e.g. `cc:31:*`).
    var omniKey: String {
        switch command {
        case .controlChange: return "cc:\(data1):*"
        case .noteOn, .noteOff: return "note:\(data1):*"
        case .pitchBend: return "pitchbend:*"
        default: return "other:\(data1):*"
        }
    }

    var shortLabel: String {
        switch command {
        case .controlChange: return "\(channel)/CC \(data1)"
        case .noteOn, .noteOff: return "\(channel)/Note \(data1)"
        case .pitchBend: return "\(channel)/PB"
        default: return "\(channel)/\(command.name)"
        }
    }

    var logDescription: String {
        switch command {
        case .controlChange:
            return "Ch \(channel)  CC \(data1)  val \(data2)"
        case .noteOn:
            return data2 > 0 ? "Ch \(channel)  Note \(data1)  vel \(data2)" : "Ch \(channel)  Note Off \(data1)"
        case .noteOff:
            return "Ch \(channel)  Note Off \(data1)"
        case .pitchBend:
            return "Ch \(channel)  PitchBend \(data2)"
        default:
            return "Ch \(channel)  \(command.name)  \(data1)"
        }
    }
}
