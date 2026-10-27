// Mac audio for meetings: while a meeting records, capture everything the Mac plays (a Core Audio process
// tap — one "System Audio Recording" permission, no screen recording) into system.wav in the meeting's
// folder: 16 kHz mono 16-bit, the same format as the mic's audio.wav, so the voice server can mix the two.
import AppKit
import AVFoundation
import CoreAudio

final class SystemAudio {
    static let enabledKey = "meetingMacAudio"
    var enabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
    func toggle() { UserDefaults.standard.set(!enabled, forKey: Self.enabledKey) }

    private(set) var folder: String? = nil
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var file: FileHandle?
    private var written: Int64 = 0                 // samples in system.wav
    private var lastHeader = Date()
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let q = DispatchQueue(label: "voicepet.system-audio")

    /// Called a few times a second with the server's meeting state.
    func sync(meeting: Bool, folder f: String) {
        if meeting, enabled, !f.isEmpty {
            if folder != f { stop(); start(f) }
        } else if folder != nil {
            stop()
        }
    }

    // MARK: recording

    private func start(_ f: String) {
        let wav = f + "/system.wav", meta = f + "/system.json"
        guard FileManager.default.fileExists(atPath: f) else { return }
        // the pet restarted mid-meeting: keep adding to the same file, with silence for the gap
        var started = Date().timeIntervalSince1970
        if FileManager.default.fileExists(atPath: wav),
           let d = try? Data(contentsOf: URL(fileURLWithPath: meta)),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let s = j["started"] as? Double {
            started = s
        } else {
            FileManager.default.createFile(atPath: wav, contents: Self.header(0))
        }
        guard let h = FileHandle(forUpdatingAtPath: wav) else { return }
        let size = Int64(h.seekToEndOfFile())
        written = max(0, (size - 44) / 2)
        let expected = Int64((Date().timeIntervalSince1970 - started) * 16000)
        if expected > written { h.write(Data(count: Int(expected - written) * 2)); written = expected }
        file = h
        writeMeta(meta, started: started, ended: false)
        folder = f
        if !startTap() { print("system audio: couldn't start the tap"); }
        else { print("system audio: recording to", wav) }
    }

    private func stop() {
        guard let f = folder else { return }
        if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p) }
        procID = nil
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = kAudioObjectUnknown }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = kAudioObjectUnknown }
        q.sync {
            updateHeader()
            try? file?.close(); file = nil
        }
        var started = Date().timeIntervalSince1970
        if let d = try? Data(contentsOf: URL(fileURLWithPath: f + "/system.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let s = j["started"] as? Double { started = s }
        writeMeta(f + "/system.json", started: started, ended: true)
        folder = nil
        print("system audio: saved", written / 16000, "s")
    }

    private func writeMeta(_ path: String, started: Double, ended: Bool) {
        let j: [String: Any] = ["started": started, "ended": ended]
        if let d = try? JSONSerialization.data(withJSONObject: j) { try? d.write(to: URL(fileURLWithPath: path)) }
    }

    private func startTap() -> Bool {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { return false }

        guard let outUID = Self.defaultOutputUID() else { return false }
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VoicePet meeting",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID) == noErr else { return false }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd) == noErr,
              let fmt = AVAudioFormat(streamDescription: &asbd) else { return false }
        inFormat = fmt
        converter = AVAudioConverter(from: fmt, to: outFormat)
        converter?.downmix = true

        let err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, q) { [weak self] _, input, _, _, _ in
            self?.consume(input)
        }
        guard err == noErr, let p = procID else { return false }
        return AudioDeviceStart(aggID, p) == noErr
    }

    /// On the audio queue: 48 kHz stereo float in, 16 kHz mono 16-bit out, appended to system.wav.
    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        guard let fmt = inFormat, let conv = converter, let file,
              let inBuf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: input, deallocator: nil),
              inBuf.frameLength > 0 else { return }
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * 16000 / fmt.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
        var fed = false
        conv.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        guard out.frameLength > 0, let ch = out.int16ChannelData else { return }
        file.write(Data(bytes: ch[0], count: Int(out.frameLength) * 2))
        written += Int64(out.frameLength)
        if Date().timeIntervalSince(lastHeader) > 5 { updateHeader() }   // readable while it records
    }

    private func updateHeader() {
        guard let file else { return }
        lastHeader = Date()
        let end = file.offsetInFile
        file.seek(toFileOffset: 0); file.write(Self.header(UInt32(written * 2))); file.seek(toFileOffset: end)
    }

    static func header(_ dataBytes: UInt32) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }

    static func defaultOutputUID() -> String? {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return nil }
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        guard withUnsafeMutablePointer(to: &uid, { AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0) }) == noErr else { return nil }
        return uid as String
    }
}
