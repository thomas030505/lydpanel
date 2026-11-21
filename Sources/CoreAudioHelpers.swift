import CoreAudio
import AudioToolbox
import Foundation

// Små hjelpere rundt Core Audio sitt C-API.

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func hasProperty(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
    var a = addr
    return AudioObjectHasProperty(obj, &a)
}

func isSettable(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
    var a = addr
    var settable: DarwinBoolean = false
    return AudioObjectIsPropertySettable(obj, &a, &settable) == noErr && settable.boolValue
}

func getValue<T: BitwiseCopyable>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, default def: T) -> T {
    var a = addr
    var value = def
    var size = UInt32(MemoryLayout<T>.size)
    let err = AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value)
    return err == noErr ? value : def
}

@discardableResult
func setValue<T: BitwiseCopyable>(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
    var a = addr
    var v = value
    return AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<T>.size), &v)
}

func getString(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> String? {
    var a = addr
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let err = AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value)
    guard err == noErr, let v = value else { return nil }
    return v.takeRetainedValue() as String
}

func getIDs(_ obj: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> [AudioObjectID] {
    var a = addr
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
}

// MARK: - Enheter

struct OutputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let name: String
    let uid: String
}

let aggregateUIDPrefix = "local.lydpanel.agg."

func listOutputDevices() -> [OutputDevice] {
    getIDs(systemObject, address(kAudioHardwarePropertyDevices)).compactMap { dev in
        let streams = getIDs(dev, address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput))
        guard !streams.isEmpty,
              let uid = getString(dev, address(kAudioDevicePropertyDeviceUID)),
              !uid.hasPrefix(aggregateUIDPrefix) else { return nil }
        let name = getString(dev, address(kAudioObjectPropertyName)) ?? "Ukjent enhet"
        return OutputDevice(id: dev, name: name, uid: uid)
    }
}

func defaultOutputDevice() -> AudioObjectID {
    getValue(systemObject, address(kAudioHardwarePropertyDefaultOutputDevice), default: AudioObjectID(kAudioObjectUnknown))
}

func setDefaultOutputDevice(_ id: AudioObjectID) {
    setValue(systemObject, address(kAudioHardwarePropertyDefaultOutputDevice), id)
    // La systemlyder følge med, slik Kontrollsenter gjør.
    setValue(systemObject, address(kAudioHardwarePropertyDefaultSystemOutputDevice), id)
}

let volumeAddress = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
let muteAddress = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)

// MARK: - Prosesser som bruker lyd

struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isPlaying: Bool
}

func listAudioProcesses() -> [AudioProcess] {
    getIDs(systemObject, address(kAudioHardwarePropertyProcessObjectList)).map { obj in
        AudioProcess(
            objectID: obj,
            pid: getValue(obj, address(kAudioProcessPropertyPID), default: pid_t(-1)),
            bundleID: getString(obj, address(kAudioProcessPropertyBundleID)),
            isPlaying: getValue(obj, address(kAudioProcessPropertyIsRunningOutput), default: UInt32(0)) != 0
        )
    }
}

/// Finner prosessen som er «ansvarlig» for en hjelpeprosess (f.eks. Safari for WebKit-lyd).
private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
private let responsibleFn: ResponsibleFn? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(sym, to: ResponsibleFn.self)
}()

func responsiblePID(for pid: pid_t) -> pid_t? {
    guard let fn = responsibleFn else { return nil }
    let r = fn(pid)
    return r > 0 ? r : nil
}
