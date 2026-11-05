import CoreAudio
import Foundation

/// Thin helpers over the Core Audio HAL property API.
extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    private func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func readValue<T>(_ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      initial: T) -> T? {
        var addr = address(sel, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let err = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(self, &addr, 0, nil, &size, $0) }
        return err == noErr ? value : nil
    }

    func readArray<T>(_ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      of: T.Type) -> [T] {
        var addr = address(sel, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        return [T](unsafeUninitializedCapacity: count) { buf, n in
            var s = size
            let err = AudioObjectGetPropertyData(self, &addr, 0, nil, &s, buf.baseAddress!)
            n = err == noErr ? Int(s) / MemoryLayout<T>.stride : 0
        }
    }

    func readString(_ sel: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(sel, scope)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = withUnsafeMutablePointer(to: &ref) { AudioObjectGetPropertyData(self, &addr, 0, nil, &size, $0) }
        guard err == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    // MARK: Devices

    var deviceUID: String? { readString(kAudioDevicePropertyDeviceUID) }
    var deviceName: String? { readString(kAudioObjectPropertyName) }

    func channelCount(scope: AudioObjectPropertyScope) -> Int {
        let streams = readArray(kAudioDevicePropertyStreams, scope: scope, of: AudioObjectID.self)
        return streams.reduce(0) { total, stream in
            let fmt = stream.readValue(kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())
            return total + Int(fmt?.mChannelsPerFrame ?? 0)
        }
    }

    /// Channel count of the first output stream, which is what a device-stream tap captures.
    var firstOutputStreamChannels: Int {
        guard let stream = readArray(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, of: AudioObjectID.self).first
        else { return 0 }
        return Int(stream.readValue(kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription())?.mChannelsPerFrame ?? 0)
    }

    static var allDevices: [AudioObjectID] {
        system.readArray(kAudioHardwarePropertyDevices, of: AudioObjectID.self)
    }

    static var defaultOutputDevice: AudioObjectID? {
        system.readValue(kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(kAudioObjectUnknown))
    }

    // MARK: Processes (macOS 14.2+)

    static var audioProcesses: [AudioObjectID] {
        system.readArray(kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)
    }

    var processBundleID: String? { readString(kAudioProcessPropertyBundleID) }
    var processPID: pid_t? { readValue(kAudioProcessPropertyPID, initial: pid_t(0)) }
    var processIsRunningOutput: Bool { (readValue(kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0 }
    var processOutputDevices: [AudioObjectID] {
        readArray(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput, of: AudioObjectID.self)
    }

    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pidValue = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &obj)
        return err == noErr && obj != kAudioObjectUnknown ? obj : nil
    }
}

struct CoreAudioError: Error, CustomStringConvertible {
    let what: String
    let status: OSStatus
    var description: String {
        let code = UInt32(bitPattern: status)
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((code >> $0) & 0xFF))) }
        let fourCC = chars.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " ") } ? " '\(String(chars))'" : ""
        return "\(what) failed (\(status)\(fourCC))"
    }
}

@discardableResult
func check(_ status: OSStatus, _ what: String) throws -> OSStatus {
    if status != noErr { throw CoreAudioError(what: what, status: status) }
    return status
}
