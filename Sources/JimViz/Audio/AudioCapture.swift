import CoreAudio
import Foundation
import QuartzCore
import Observation

/// Captures one source into a mono ring buffer: Rekordbox (via a Core Audio process tap),
/// all system audio, or an input device, on one channel pair. A once-a-second monitor
/// reconnects when Rekordbox starts, quits, or switches output device.
///
/// When Rekordbox plays to a multichannel interface like the DDJ-FLX4, the tap captures that
/// device's stream directly so only the chosen channel pair (master, by default) is analysed
/// and the headphone cue is ignored.
///
/// The source and pair are fixed; `AudioCaptures` keeps one per source in use, shared by every
/// scene's Audio In that listens to it.
@Observable
final class AudioCapture {
    enum Source: Hashable {
        case rekordbox
        case systemAudio
        case input(uid: String)

        /// As saved in a scene's Audio In `device`: `rekordbox`, `system` or `input:<uid>`.
        var key: String {
            switch self {
            case .rekordbox: return "rekordbox"
            case .systemAudio: return "system"
            case .input(let uid): return "input:\(uid)"
            }
        }

        init?(key: String) {
            switch key {
            case "rekordbox": self = .rekordbox
            case "system": self = .systemAudio
            case let k where k.hasPrefix("input:") && k.count > 6: self = .input(uid: String(k.dropFirst(6)))
            default: return nil
            }
        }
    }

    enum Health: Equatable { case off, waiting, running, silent, error }

    struct InputDevice: Identifiable, Hashable {
        let id: String // UID
        let name: String
    }

    let source: Source
    /// Which stereo pair of the tapped device or input to listen to (0 is channels 1–2).
    let channelPair: Int
    private(set) var health: Health = .off
    private(set) var statusText = "Not in use"
    /// Number of selectable stereo pairs on the tapped device (1 for a stereo mixdown).
    private(set) var channelPairs = 1

    @ObservationIgnored let ring: SampleRing
    /// Beat and bar tracking on this source, running only while a Clock follows it.
    @ObservationIgnored let beats: LiveBeatTracker
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "jim-viz.audio", qos: .userInteractive)
    @ObservationIgnored private var tapID = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var ioDevice = AudioObjectID(kAudioObjectUnknown)
    @ObservationIgnored private var procID: AudioDeviceIOProcID?
    /// Describes what is currently tapped, so the monitor can tell when it must rebuild.
    @ObservationIgnored private var tappedSignature: String?
    @ObservationIgnored private var silentSince: CFAbsoluteTime?
    @ObservationIgnored private var monitor: Timer?
    @ObservationIgnored private var describeRunning = ""

    static let rekordboxBundlePrefix = "com.pioneerdj.rekordbox"
    /// Which processes count as "Rekordbox". Tests point this at another process.
    @ObservationIgnored var processFilter: (AudioObjectID) -> Bool = {
        $0.processBundleID?.lowercased().hasPrefix(AudioCapture.rekordboxBundlePrefix) == true
    }

    init(source: Source, channelPair: Int) {
        self.source = source
        self.channelPair = channelPair
        ring = SampleRing()
        beats = LiveBeatTracker(ring: ring)
    }

    /// True while a scene on screen listens to it. Capture runs only then.
    private(set) var isActive = false

    /// Starts capturing (and the reconnect monitor) or stops and releases the tap.
    func setActive(_ on: Bool) {
        guard on != isActive else { return }
        isActive = on
        if on {
            reconcile()
            monitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.reconcile() }
        } else {
            monitor?.invalidate()
            monitor = nil
            teardown()
            set(.off, "Not in use")
        }
    }

    /// Every input device with input channels, except jim-viz's own aggregate devices.
    static func inputDevices() -> [InputDevice] {
        AudioObjectID.allDevices.compactMap { dev in
            guard dev.channelCount(scope: kAudioObjectPropertyScopeInput) > 0,
                  let uid = dev.deviceUID, let name = dev.deviceName,
                  !uid.hasPrefix("jim-viz") else { return nil }
            return InputDevice(id: uid, name: name)
        }
    }

    // MARK: Reconcile

    /// Works out what should be tapped right now and rebuilds if it changed.
    private func reconcile() {
        switch source {
        case .rekordbox:
            reconcileRekordbox()
        case .systemAudio:
            ensure(signature: "system") { try startSystemTap() }
        case .input(let uid):
            ensure(signature: "input:\(uid):\(channelPair)") { try startInput(uid: uid) }
        }
        updateSilence()
    }

    private func reconcileRekordbox() {
        let procs = AudioObjectID.audioProcesses.filter(processFilter)
        guard !procs.isEmpty else {
            teardown()
            set(.waiting, "Waiting for Rekordbox to play audio")
            return
        }
        let device = procs.flatMap(\.processOutputDevices).first
        let uid = device?.deviceUID
        let signature = "rekordbox:\(procs.sorted()):\(uid ?? "-"):\(channelPair)"
        ensure(signature: signature) { try startRekordboxTap(procs, device: device) }
    }

    private func ensure(signature: String, start: () throws -> Void) {
        guard signature != tappedSignature else { return }
        teardown()
        do {
            try start()
            tappedSignature = signature
            set(.running, describeRunning)
        } catch {
            teardown()
            // Remember the failure so we don't retry every second; a change in setup retries.
            tappedSignature = signature
            set(.error, "\(error)")
        }
    }

    private func updateSilence() {
        guard health == .running || health == .silent else { silentSince = nil; return }
        let now = CFAbsoluteTimeGetCurrent()
        let stale = now - ring.lastWriteTime > 2
        let quiet = ring.lastBlockPeak < 0.003 // about -50 dBFS
        if stale || quiet {
            if silentSince == nil { silentSince = now }
            if now - silentSince! > 3 {
                let hint: String
                let permission = "allow jim-viz (or the terminal running it) in System Settings › Privacy & Security › Screen & System Audio Recording"
                if stale {
                    hint = "No audio arriving"
                } else if source == .rekordbox,
                          AudioObjectID.audioProcesses.contains(where: {
                              $0.processBundleID?.lowercased().hasPrefix(Self.rekordboxBundlePrefix) == true && $0.processIsRunningOutput }) {
                    hint = "Rekordbox is playing but jim-viz hears silence: \(permission)"
                } else if case .input = source {
                    hint = "Silent. If the input has signal, allow microphone access for jim-viz"
                } else {
                    hint = "Silent. If audio is playing, \(permission)"
                }
                set(.silent, hint)
            }
        } else {
            silentSince = nil
            if health == .silent { set(.running, describeRunning) }
        }
    }

    private func set(_ h: Health, _ text: String) {
        if health != h { health = h }
        if statusText != text { statusText = text }
    }

    // MARK: Starting sources

    private func startRekordboxTap(_ procs: [AudioObjectID], device: AudioObjectID?) throws {
        let deviceName = device?.deviceName ?? "output"
        // Tap the device stream directly when it has more than two channels, so cue audio is excluded.
        if let device, let uid = device.deviceUID, device.firstOutputStreamChannels > 2 {
            let desc = CATapDescription(processes: procs, deviceUID: uid, stream: 0)
            do {
                let channels = try startTap(desc, clockDeviceUID: uid)
                channelPairs = max(1, channels / 2)
                let pair = min(channelPair, channelPairs - 1)
                describeRunning = "Rekordbox → \(deviceName), ch \(pair * 2 + 1)–\(pair * 2 + 2), \(rateText)"
                return
            } catch {
                teardown() // fall through to a stereo mixdown
            }
        }
        let desc = CATapDescription(stereoMixdownOfProcesses: procs)
        _ = try startTap(desc, clockDeviceUID: device?.deviceUID)
        channelPairs = 1
        describeRunning = "Rekordbox → \(deviceName), stereo mix, \(rateText)"
    }

    private func startSystemTap() throws {
        let own = AudioObjectID.processObject(for: getpid()).map { [$0] } ?? []
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: own)
        _ = try startTap(desc, clockDeviceUID: nil)
        channelPairs = 1
        describeRunning = "System audio, \(rateText)"
    }

    private func startInput(uid: String) throws {
        guard let dev = AudioObjectID.allDevices.first(where: { $0.deviceUID == uid }) else {
            throw CoreAudioError(what: "find input device", status: OSStatus(kAudioHardwareBadDeviceError))
        }
        let rate = dev.readValue(kAudioDevicePropertyNominalSampleRate, initial: Float64(48000)) ?? 48000
        ring.setSampleRate(rate)
        let channels = dev.channelCount(scope: kAudioObjectPropertyScopeInput)
        channelPairs = max(1, (channels + 1) / 2)
        try startIO(on: dev)
        let pair = min(channelPair, channelPairs - 1)
        describeRunning = "\(dev.deviceName ?? "Input"), ch \(pair * 2 + 1)–\(min(pair * 2 + 2, channels)), \(rateText)"
    }

    /// Creates the tap and a private aggregate device to read it. Returns the tap's channel count.
    private func startTap(_ desc: CATapDescription, clockDeviceUID: String?) throws -> Int {
        desc.name = "jim-viz"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(desc, &tap), "Create process tap")
        tapID = tap

        guard let fmt = tap.readValue(kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()),
              fmt.mFormatID == kAudioFormatLinearPCM, fmt.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw CoreAudioError(what: "Read tap format", status: OSStatus(kAudioHardwareUnsupportedOperationError))
        }
        ring.setSampleRate(fmt.mSampleRate)

        let mainUID = clockDeviceUID ?? AudioObjectID.defaultOutputDevice?.deviceUID ?? ""
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "jim-viz tap",
            kAudioAggregateDeviceUIDKey: "jim-viz-tap-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: mainUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: mainUID.isEmpty ? [] : [[kAudioSubDeviceUIDKey: mainUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg), "Create aggregate device")
        aggregateID = agg
        // The aggregate's inputs are the clock device's own hardware inputs (if any) followed by
        // the tap. Read only the tap's channels, which are the last ones.
        try startIO(on: agg, tapChannels: Int(fmt.mChannelsPerFrame))
        return Int(fmt.mChannelsPerFrame)
    }

    /// `tapChannels`: when set, only the last that-many input channels are used.
    private func startIO(on device: AudioObjectID, tapChannels: Int? = nil) throws {
        let ring = self.ring
        let pair = channelPair
        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, ioQueue) { _, input, inputTime, _, _ in
            let t = inputTime.pointee
            let host = t.mFlags.contains(.hostTimeValid)
                ? Double(AudioConvertHostTimeToNanos(t.mHostTime)) / 1e9 : CACurrentMediaTime()
            Self.consume(input, pair: pair, tapChannels: tapChannels, hostTime: host, into: ring)
        }, "Create IO proc")
        procID = proc
        ioDevice = device
        try check(AudioDeviceStart(device, proc), "Start audio device")
    }

    /// Mixes the chosen channel pair to mono and writes it to the ring. Handles both
    /// interleaved and per-channel buffer layouts.
    private static func consume(_ input: UnsafePointer<AudioBufferList>, pair: Int, tapChannels: Int?,
                                hostTime: CFTimeInterval, into ring: SampleRing) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var total = 0
        for b in abl { total += Int(b.mNumberChannels) }
        guard total > 0 else { return }
        let base = tapChannels.map { max(0, total - $0) } ?? 0
        let left = min(base + pair * 2, total - 1)
        let right = min(left + 1, total - 1)

        // Locate (buffer, channel-in-buffer) for a flat channel index.
        func locate(_ flat: Int) -> (UnsafePointer<Float>, Int, Int)? {
            var base = 0
            for b in abl {
                let n = Int(b.mNumberChannels)
                if flat < base + n, let data = b.mData {
                    return (UnsafePointer(data.assumingMemoryBound(to: Float.self)), flat - base, n)
                }
                base += n
            }
            return nil
        }
        guard let (lp, lc, ln) = locate(left), let (rp, rc, rn) = locate(right) else { return }
        let frames = Int(abl[0].mDataByteSize) / (MemoryLayout<Float>.size * max(Int(abl[0].mNumberChannels), 1))
        ring.write(frames: frames, hostTime: hostTime) { i in (lp[i * ln + lc] + rp[i * rn + rc]) * 0.5 }
    }

    private var rateText: String {
        String(format: "%.1f kHz", ring.sampleRate / 1000).replacingOccurrences(of: ".0 ", with: " ")
    }

    // MARK: Teardown

    private func teardown() {
        if let procID, ioDevice != kAudioObjectUnknown {
            AudioDeviceStop(ioDevice, procID)
            AudioDeviceDestroyIOProcID(ioDevice, procID)
        }
        procID = nil
        ioDevice = AudioObjectID(kAudioObjectUnknown)
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        if tappedSignature != nil {
            tappedSignature = nil
            ring.reset()
        }
        silentSince = nil
    }

    deinit { teardown() }
}

/// Every audio source the scenes listen to: one capture per source and channel pair, shared
/// by the scenes that use it. Captures run only while a scene on screen uses them.
@Observable
final class AudioCaptures {
    /// Input devices, for the source menu and the browser.
    private(set) var inputDevices: [AudioCapture.InputDevice] = []
    @ObservationIgnored private var captures: [String: AudioCapture] = [:]

    /// The capture for a source and pair, made on first use.
    func capture(_ source: AudioCapture.Source, channelPair: Int) -> AudioCapture {
        let key = "\(source.key)#\(channelPair)"
        if let c = captures[key] { return c }
        let c = AudioCapture(source: source, channelPair: channelPair)
        captures[key] = c
        return c
    }

    /// Every capture made so far, running or not.
    var all: [AudioCapture] { Array(captures.values) }

    /// Runs exactly these captures.
    func activate(_ active: [AudioCapture]) {
        let ids = Set(active.map(ObjectIdentifier.init))
        for c in captures.values { c.setActive(ids.contains(ObjectIdentifier(c))) }
    }

    func refreshInputDevices() {
        let found = AudioCapture.inputDevices()
        if found != inputDevices { inputDevices = found }
    }

    /// "Rekordbox", "System Audio", or the input device's name.
    func label(_ source: AudioCapture.Source) -> String {
        switch source {
        case .rekordbox: return "Rekordbox"
        case .systemAudio: return "System Audio"
        case .input(let uid): return inputDevices.first { $0.id == uid }?.name ?? "Input (not connected)"
        }
    }
}
