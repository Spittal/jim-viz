import CoreMIDI
import Foundation
import Observation

/// CoreMIDI manager: connects to every active USB and virtual MIDI source, parses MIDI
/// channel messages, and hands them to the engine (`MIDIMap`). Devices aren't told apart.
@Observable
final class MIDIEngine {
    private(set) var isConnected: Bool = false

    @ObservationIgnored private var client = MIDIClientRef()
    @ObservationIgnored private var inPort = MIDIPortRef()
    @ObservationIgnored private let queue = DispatchQueue(label: "jim-viz.midi", qos: .userInteractive)
    @ObservationIgnored private var connectedSources: Set<MIDIEndpointRef> = []

    /// Receives every message, on main. The engine routes them to mappings and MIDI map mode.
    @ObservationIgnored var onMessage: ((MIDIMessage) -> Void)?
    /// True while something is mapped to MIDI or MIDI map mode is on. Sources are connected only then.
    private(set) var isActive = false

    init() {
        setupClient()
    }

    deinit {
        stop()
    }

    /// Connects every source, or disconnects them all.
    func setActive(_ on: Bool) {
        guard on != isActive else { return }
        isActive = on
        if !on {
            for src in connectedSources { MIDIPortDisconnectSource(inPort, src) }
            connectedSources.removeAll()
            isConnected = false
        }
        refreshEndpoints()
    }

    func stop() {
        if inPort != 0 {
            MIDIPortDispose(inPort)
            inPort = 0
        }
        if client != 0 {
            MIDIClientDispose(client)
            client = 0
        }
        connectedSources.removeAll()
        isConnected = false
    }

    private func setupClient() {
        var newClient = MIDIClientRef()
        let status = MIDIClientCreateWithBlock("jim-viz.midi" as CFString, &newClient) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshEndpoints()
            }
        }
        guard status == noErr else { return }
        self.client = newClient

        var port = MIDIPortRef()
        let portStatus = MIDIInputPortCreateWithProtocol(
            newClient,
            "jim-viz.in" as CFString,
            ._1_0,
            &port
        ) { [weak self] eventListPtr, srcConnRef in
            self?.handleEvents(eventListPtr)
        }

        if portStatus == noErr {
            self.inPort = port
        } else {
            // Fallback for older packet lists
            var oldPort = MIDIPortRef()
            let oldStatus = MIDIInputPortCreateWithBlock(
                newClient,
                "jim-viz.in" as CFString,
                &oldPort
            ) { [weak self] packetListPtr, srcConnRef in
                self?.handlePacketList(packetListPtr)
            }
            if oldStatus == noErr {
                self.inPort = oldPort
            }
        }

        refreshEndpoints()
    }

    /// Connects every available MIDI source while active.
    func refreshEndpoints() {
        guard inPort != 0 else { return }
        var newlyConnected: Set<MIDIEndpointRef> = []
        for i in 0..<MIDIGetNumberOfSources() {
            let src = MIDIGetSource(i)
            var offline: Int32 = 0
            MIDIObjectGetIntegerProperty(src, kMIDIPropertyOffline, &offline)
            guard offline == 0, isActive else { continue }
            if !connectedSources.contains(src) { MIDIPortConnectSource(inPort, src, nil) }
            newlyConnected.insert(src)
        }
        connectedSources = newlyConnected
        isConnected = !newlyConnected.isEmpty
    }

    // MARK: - Packet Parsing

    private func handleEvents(_ eventListPtr: UnsafePointer<MIDIEventList>) {
        for message in Self.channelMessages(in: eventListPtr) {
            parseBytes(status: message.status, d1: message.d1, d2: message.d2, time: message.time)
        }
    }

    /// Every MIDI 1.0 channel message in an event list. A packet holds as many messages as
    /// share its timestamp, one word each, among other message types of one to four words.
    static func channelMessages(in eventListPtr: UnsafePointer<MIDIEventList>)
        -> [(status: UInt8, d1: UInt8, d2: UInt8, time: MIDITimeStamp)] {
        let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \.words)!
        var messages: [(status: UInt8, d1: UInt8, d2: UInt8, time: MIDITimeStamp)] = []
        for packet in eventListPtr.unsafeSequence() {
            let words = UnsafeRawPointer(packet).advanced(by: wordsOffset).assumingMemoryBound(to: UInt32.self)
            let count = Int(packet.pointee.wordCount)
            var i = 0
            while i < count {
                let word = words[i]
                let type = word >> 28
                if type == 0x2 {
                    messages.append((UInt8((word >> 16) & 0xFF), UInt8((word >> 8) & 0xFF), UInt8(word & 0xFF),
                                     packet.pointee.timeStamp))
                }
                i += [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4][Int(type)]
            }
        }
        return messages
    }

    private func handlePacketList(_ packetListPtr: UnsafePointer<MIDIPacketList>) {
        var packet = packetListPtr.pointee.packet
        for _ in 0..<packetListPtr.pointee.numPackets {
            let length = Int(packet.length)
            withUnsafePointer(to: packet.data) { dataPtr in
                dataPtr.withMemoryRebound(to: UInt8.self, capacity: length) { bytes in
                    var idx = 0
                    while idx < length {
                        let status = bytes[idx]
                        if status >= 0x80 && status < 0xF0 {
                            let d1 = idx + 1 < length ? bytes[idx + 1] : 0
                            let d2 = idx + 2 < length ? bytes[idx + 2] : 0
                            parseBytes(status: status, d1: d1, d2: d2, time: packet.timeStamp)
                            idx += 3
                        } else {
                            idx += 1
                        }
                    }
                }
            }
            packet = MIDIPacketNext(&packet).pointee
        }
    }

    private func parseBytes(status: UInt8, d1: UInt8, d2: UInt8, time: MIDITimeStamp) {
        let cmdNibble = status & 0xF0
        let ch = Int((status & 0x0F) + 1)
        guard let command = MIDICommand(rawValue: cmdNibble) else { return }

        let msg = MIDIMessage(
            channel: ch,
            command: command,
            data1: Int(d1 & 0x7F),
            data2: Int(d2 & 0x7F),
            timestamp: time
        )
        DispatchQueue.main.async {
            self.onMessage?(msg)
        }
    }
}
