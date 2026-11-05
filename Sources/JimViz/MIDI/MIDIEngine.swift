import CoreMIDI
import Foundation
import Observation

struct MIDIDeviceInfo: Identifiable, Hashable {
    let id: Int32
    let name: String
    let sourceCount: Int
    var isEnabled: Bool = true
}

/// CoreMIDI manager: discovers and connects to all active USB and virtual MIDI input sources,
/// parses MIDI channel packets, and dispatches them to parameter mappings and MIDI learn.
@Observable
final class MIDIEngine {
    private(set) var devices: [MIDIDeviceInfo] = []
    private(set) var isConnected: Bool = false
    private(set) var lastMessageText: String = "No MIDI received"
    private(set) var lastActivityTime: CFAbsoluteTime = 0

    @ObservationIgnored private var client = MIDIClientRef()
    @ObservationIgnored private var inPort = MIDIPortRef()
    @ObservationIgnored private let queue = DispatchQueue(label: "jim-viz.midi", qos: .userInteractive)
    @ObservationIgnored private var connectedSources: Set<MIDIEndpointRef> = []

    /// Global message listeners (such as MIDI learn or live monitor).
    @ObservationIgnored var onMessage: ((MIDIMessage) -> Void)?

    init() {
        setupClient()
    }

    deinit {
        stop()
    }

    func start() {
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
            self?.handleEvents(eventListPtr, device: Self.deviceName(srcConnRef))
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
                self?.handlePacketList(packetListPtr, device: Self.deviceName(srcConnRef))
            }
            if oldStatus == noErr {
                self.inPort = oldPort
            }
        }

        refreshEndpoints()
    }

    /// Discovers all available MIDI sources and connects to them.
    func refreshEndpoints() {
        guard inPort != 0 else { return }

        var devList: [MIDIDeviceInfo] = []
        let numDevs = MIDIGetNumberOfDevices()
        for i in 0..<numDevs {
            let dev = MIDIGetDevice(i)
            var offline: Int32 = 0
            MIDIObjectGetIntegerProperty(dev, kMIDIPropertyOffline, &offline)
            guard offline == 0 else { continue }

            var devName: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(dev, kMIDIPropertyName, &devName)
            var uniqueID: Int32 = Int32(i)
            MIDIObjectGetIntegerProperty(dev, kMIDIPropertyUniqueID, &uniqueID)

            let entCount = MIDIDeviceGetNumberOfEntities(dev)
            var srcCount = 0
            for e in 0..<entCount {
                srcCount += MIDIEntityGetNumberOfSources(MIDIDeviceGetEntity(dev, e))
            }

            let name = (devName?.takeRetainedValue() as String?) ?? "MIDI Device \(i)"
            devList.append(MIDIDeviceInfo(id: uniqueID, name: name, sourceCount: srcCount))
        }

        let numSources = MIDIGetNumberOfSources()
        var newlyConnected: Set<MIDIEndpointRef> = []

        for i in 0..<numSources {
            let src = MIDIGetSource(i)
            var offline: Int32 = 0
            MIDIObjectGetIntegerProperty(src, kMIDIPropertyOffline, &offline)
            guard offline == 0 else { continue }

            if !connectedSources.contains(src) {
                // The endpoint rides along as the connection's refCon, so messages know their device.
                MIDIPortConnectSource(inPort, src, UnsafeMutableRawPointer(bitPattern: Int(src)))
            }
            newlyConnected.insert(src)
        }

        connectedSources = newlyConnected
        devices = devList
        isConnected = !newlyConnected.isEmpty
    }

    /// Device name for a source endpoint passed as a connection refCon. Virtual sources,
    /// which have no device, use their own name. Called on CoreMIDI's thread.
    private static func deviceName(_ refCon: UnsafeMutableRawPointer?) -> String? {
        guard let refCon else { return nil }
        let src = MIDIEndpointRef(truncatingIfNeeded: Int(bitPattern: refCon))
        var entity = MIDIEntityRef(), device = MIDIDeviceRef()
        var object: MIDIObjectRef = src
        if MIDIEndpointGetEntity(src, &entity) == noErr, entity != 0,
           MIDIEntityGetDevice(entity, &device) == noErr, device != 0 {
            object = device
        }
        var name: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, kMIDIPropertyName, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    // MARK: - Packet Parsing

    private func handleEvents(_ eventListPtr: UnsafePointer<MIDIEventList>, device: String?) {
        var packet = eventListPtr.pointee.packet
        for _ in 0..<eventListPtr.pointee.numPackets {
            let words = Mirror(reflecting: packet.words).children.compactMap { $0.value as? UInt32 }
            if let firstWord = words.first {
                let status = UInt8((firstWord >> 16) & 0xFF)
                let data1 = UInt8((firstWord >> 8) & 0xFF)
                let data2 = UInt8(firstWord & 0xFF)
                parseBytes(status: status, d1: data1, d2: data2, time: packet.timeStamp, device: device)
            }
            packet = MIDIEventPacketNext(&packet).pointee
        }
    }

    private func handlePacketList(_ packetListPtr: UnsafePointer<MIDIPacketList>, device: String?) {
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
                            parseBytes(status: status, d1: d1, d2: d2, time: packet.timeStamp, device: device)
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

    private func parseBytes(status: UInt8, d1: UInt8, d2: UInt8, time: MIDITimeStamp, device: String?) {
        let cmdNibble = status & 0xF0
        let ch = Int((status & 0x0F) + 1)
        guard let command = MIDICommand(rawValue: cmdNibble) else { return }

        let msg = MIDIMessage(
            channel: ch,
            command: command,
            data1: Int(d1 & 0x7F),
            data2: Int(d2 & 0x7F),
            timestamp: time,
            device: device
        )

        let now = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async {
            self.lastMessageText = msg.logDescription
            self.lastActivityTime = now
            self.onMessage?(msg)
        }
    }
}
