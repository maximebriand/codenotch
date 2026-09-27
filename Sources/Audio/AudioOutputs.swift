import AudioToolbox
import CoreAudio
import Foundation

/// The Mac's sound outputs, and which one is playing — read from and written
/// to Core Audio directly, the same switch the Sound menu in Control Centre
/// flips.
enum AudioOutputs {
    struct Device: Identifiable, Equatable {
        enum Kind: Equatable { case builtIn, headphones, display, airPlay, usb, other }
        let id: AudioDeviceID
        let name: String
        let kind: Kind
    }

    struct State: Equatable {
        var devices: [Device]
        var current: AudioDeviceID?
        /// 0…1, or nil for a device with no volume of its own — an HDMI
        /// display often has none, and its volume lives on the display.
        var volume: Float?
        /// The microphone every app records from by default.
        var microphone: Microphone?

        static let empty = State(devices: [], current: nil, volume: nil, microphone: nil)

        var currentDevice: Device? { devices.first { $0.id == current } }
    }

    static func read() -> State {
        let current = defaultOutput()
        return State(devices: outputDevices(), current: current,
                     volume: current.flatMap(volume(of:)),
                     microphone: defaultInput().map(microphone(_:)))
    }

    // MARK: - Microphone

    struct Microphone: Equatable {
        let id: AudioDeviceID
        let name: String
        /// Nil for a microphone with neither a mute switch nor a volume to
        /// take to zero — rare, but a button that cannot work must not show.
        let isMuted: Bool?
        /// Some app is recording from it right now — in a call, as far as the
        /// notch is concerned. Teams, Zoom, Meet in a browser: all of them
        /// open the microphone, and none of them says so any other way.
        let isInUse: Bool
    }

    static func defaultInput() -> AudioDeviceID? {
        let id: AudioDeviceID? = value(AudioObjectID(kAudioObjectSystemObject),
                                       kAudioHardwarePropertyDefaultInputDevice)
        return id == kAudioObjectUnknown ? nil : id
    }

    static func microphone(_ id: AudioDeviceID) -> Microphone {
        let running: UInt32 = value(id, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0
        return Microphone(id: id, name: string(id, kAudioObjectPropertyName) ?? L10n.t("Microphone"),
                          isMuted: isMicrophoneMuted(id), isInUse: running != 0)
    }

    private static func isMicrophoneMuted(_ id: AudioDeviceID) -> Bool? {
        if let mute: UInt32 = value(id, kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeInput) {
            return mute != 0
        }
        if let volume: Float = value(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                     scope: kAudioDevicePropertyScopeInput) {
            return volume == 0
        }
        return nil
    }

    /// Mute the microphone for every app at once — below Teams, which keeps
    /// showing its own button as live while hearing nothing.
    ///
    /// The device's mute switch where it has one. Otherwise its input volume
    /// goes to zero, and back to what it was.
    @discardableResult
    static func setMicrophoneMuted(_ muted: Bool, _ id: AudioDeviceID) -> Bool {
        if set(id, kAudioDevicePropertyMute, UInt32(muted ? 1 : 0), scope: kAudioDevicePropertyScopeInput) {
            return true
        }
        let key = "codenotch.micVolumeBeforeMute.\(id)"
        if muted {
            if let volume: Float = value(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                         scope: kAudioDevicePropertyScopeInput), volume > 0 {
                UserDefaults.standard.set(volume, forKey: key)
            }
            return set(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, Float(0),
                       scope: kAudioDevicePropertyScopeInput)
        }
        let restored = UserDefaults.standard.object(forKey: key) as? Float ?? 0.75
        return set(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, restored,
                   scope: kAudioDevicePropertyScopeInput)
    }

    // MARK: - Devices

    static func outputDevices() -> [Device] {
        let ids: [AudioDeviceID] = array(AudioObjectID(kAudioObjectSystemObject),
                                         kAudioHardwarePropertyDevices)
        return ids.compactMap { id in
            // Only what can be chosen as the output: aggregate helpers and
            // the virtual devices meeting apps install are not.
            guard hasOutputStreams(id), canBeDefaultOutput(id),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(id: id, name: name, kind: kind(of: id))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func defaultOutput() -> AudioDeviceID? {
        let id: AudioDeviceID? = value(AudioObjectID(kAudioObjectSystemObject),
                                       kAudioHardwarePropertyDefaultOutputDevice)
        return id == kAudioObjectUnknown ? nil : id
    }

    /// Make a device the output — for everything, alerts included, the way
    /// Control Centre does, so the next beep does not come out of the old one.
    @discardableResult
    static func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let main = set(system, kAudioHardwarePropertyDefaultOutputDevice, id)
        _ = set(system, kAudioHardwarePropertyDefaultSystemOutputDevice, id)
        return main
    }

    // MARK: - Volume

    /// The volume the menu bar slider shows: Core Audio's "virtual main"
    /// volume, which covers devices that only have per-channel controls.
    static func volume(of id: AudioDeviceID) -> Float? {
        value(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
    }

    @discardableResult
    static func setVolume(_ volume: Float, of id: AudioDeviceID) -> Bool {
        set(id, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            min(max(volume, 0), 1), scope: kAudioDevicePropertyScopeOutput)
    }

    // MARK: - What kind of device

    static func kind(of id: AudioDeviceID) -> Device.Kind {
        let transport: UInt32 = value(id, kAudioDevicePropertyTransportType) ?? 0
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .headphones
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI:
            return .display
        case kAudioDeviceTransportTypeAirPlay:
            return .airPlay
        case kAudioDeviceTransportTypeUSB:
            return .usb
        case kAudioDeviceTransportTypeBuiltIn:
            // The built-in output is the speakers or the headphone jack,
            // whichever is in use; its data source says which.
            let source: UInt32 = value(id, kAudioDevicePropertyDataSource,
                                       scope: kAudioDevicePropertyScopeOutput) ?? 0
            return source == fourCC("hdpn") ? .headphones : .builtIn
        default:
            return .other
        }
    }

    private static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func canBeDefaultOutput(_ id: AudioDeviceID) -> Bool {
        let flag: UInt32 = value(id, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                                 scope: kAudioDevicePropertyScopeOutput) ?? 0
        return flag != 0
    }

    // MARK: - Core Audio plumbing

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func value<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = address(selector, scope: scope)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    @discardableResult
    private static func set<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var address = address(selector, scope: scope)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue
        else { return false }
        var copy = value
        return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<T>.size), &copy) == noErr
    }

    private static func array<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [T] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer) == noErr else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var name: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let name else { return nil }
        return name.takeRetainedValue() as String
    }
}

/// Keeps `AudioOutputs.State` current: a device plugged in or out, the output
/// switched from Control Centre, the volume keys pressed.
@MainActor
final class AudioOutputMonitor {
    var onChange: ((AudioOutputs.State) -> Void)?
    private(set) var state = AudioOutputs.State.empty

    private var volumeListenedDevice: AudioDeviceID?
    private let queue = DispatchQueue.main
    private lazy var systemListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.reload() }
    }
    private lazy var volumeListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.reload() }
    }

    nonisolated init() {}

    func start() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioOutputs.address(selector)
            AudioObjectAddPropertyListenerBlock(system, &address, queue, systemListener)
        }
        reload()
    }

    func select(_ id: AudioDeviceID) {
        AudioOutputs.setDefaultOutput(id)
        reload()
    }

    func setVolume(_ volume: Float) {
        guard let current = state.current else { return }
        AudioOutputs.setVolume(volume, of: current)
        // The listener reports it too; setting it here keeps the slider from
        // stuttering between the drag and the callback.
        state.volume = volume
        onChange?(state)
    }

    func setMicrophoneMuted(_ muted: Bool) {
        guard let microphone = state.microphone else { return }
        AudioOutputs.setMicrophoneMuted(muted, microphone.id)
        reload()
    }

    private func reload() {
        let fresh = AudioOutputs.read()
        followVolume(of: fresh.current)
        followMicrophone(fresh.microphone?.id)
        guard fresh != state else { return }
        state = fresh
        onChange?(fresh)
    }

    private var micListenedDevice: AudioDeviceID?
    private lazy var micListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.reload() }
    }
    private static let micSelectors: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
        (kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput),
        (kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeInput),
    ]

    /// A call starting is the microphone starting to run, so the listener
    /// sits on whichever microphone is the default.
    private func followMicrophone(_ device: AudioDeviceID?) {
        guard device != micListenedDevice else { return }
        for (selector, scope) in Self.micSelectors {
            var address = AudioOutputs.address(selector, scope: scope)
            if let old = micListenedDevice {
                AudioObjectRemovePropertyListenerBlock(old, &address, queue, micListener)
            }
            if let device {
                AudioObjectAddPropertyListenerBlock(device, &address, queue, micListener)
            }
        }
        micListenedDevice = device
    }

    /// The volume is a property of the device, so its listener moves with
    /// the output.
    private func followVolume(of device: AudioDeviceID?) {
        guard device != volumeListenedDevice else { return }
        var address = AudioOutputs.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                           scope: kAudioDevicePropertyScopeOutput)
        if let old = volumeListenedDevice {
            AudioObjectRemovePropertyListenerBlock(old, &address, queue, volumeListener)
        }
        if let device {
            AudioObjectAddPropertyListenerBlock(device, &address, queue, volumeListener)
        }
        volumeListenedDevice = device
    }
}
