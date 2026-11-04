import CoreAudio
import Foundation

/// Mutes the Mac's speakers while recording, so a playing video doesn't talk over you, and unmutes
/// when recording ends. It only undoes what it did: sound that was already muted stays muted.
///
/// Mutes rather than pauses: the only app-independent pause is the play/pause media key, which
/// toggles, so it would start music when nothing was playing. A muted video keeps playing.
enum AudioMuter {
    /// The muted speakers' ID, saved so a crash or watchdog restart still unmutes on next launch.
    private static let savedKey = "mutedOutputDeviceUID"

    /// Mutes the current speakers if they're playing out loud. Main thread only.
    static func mute() {
        guard UserDefaults.standard.string(forKey: savedKey) == nil,
              let device = defaultOutput(), let uid = uid(of: device) else { return }
        guard let muted = isMuted(device) else {
            Log.write("mute: speakers can't be muted by apps")
            return
        }
        guard !muted, setMute(device, true) else { return }
        UserDefaults.standard.set(uid, forKey: savedKey)
    }

    /// Unmutes the speakers this app muted, if any. Safe to call any time.
    static func restore() {
        guard let uid = UserDefaults.standard.string(forKey: savedKey) else { return }
        UserDefaults.standard.removeObject(forKey: savedKey)
        if let device = device(uid: uid) { _ = setMute(device, false) }
    }

    // MARK: Core Audio

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func uid(of device: AudioDeviceID) -> String? {
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var addr = address(kAudioDevicePropertyDeviceUID)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func device(uid: String) -> AudioDeviceID? {
        var cfUID = uid as CFString
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &device)
        }
        return status == noErr && device != 0 ? device : nil
    }

    /// nil when the speakers have no mute switch apps can use (some monitor speakers).
    private static func isMuted(_ device: AudioDeviceID) -> Bool? {
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &addr),
              AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func setMute(_ device: AudioDeviceID, _ mute: Bool) -> Bool {
        var addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        var value: UInt32 = mute ? 1 : 0
        let status = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        if status != noErr { Log.write("mute: set \(mute) failed (\(status))") }
        return status == noErr
    }
}
