import AppKit
import AudioToolbox
import CoreAudio
import Foundation

/// Per-app volume: Teams quieter than the music, or the other way round.
///
/// macOS has no such control, so it is built from two pieces Core Audio has
/// offered since 14.2. A *process tap* takes an app's sound and — with
/// `mutedWhenTapped` — silences it at the source; a private aggregate device
/// then plays what the tap heard into the current output, scaled. At 100 % no
/// tap exists at all: the app plays straight to the speakers as it always did,
/// and nothing of ours is in the path.
enum AppAudio {
    /// An app that has opened the audio system, as the sound card lists it.
    struct App: Identifiable, Equatable {
        let bundleID: String
        let name: String
        /// Its processes — an app like Teams or Chrome plays from helpers.
        let processes: [AudioObjectID]
        let isPlaying: Bool
        var id: String { bundleID }
    }

    /// Every running app with an audio process, grouped the way you think of
    /// them: Chrome's helpers under Chrome, Teams' under Teams.
    static func apps() -> [App] {
        let objects = processObjects()
        var apps: [App] = []
        for running in NSWorkspace.shared.runningApplications {
            guard running.activationPolicy == .regular,
                  let bundleID = running.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier else { continue }
            let mine = objects.filter { $0.bundleID == bundleID || $0.bundleID.hasPrefix(bundleID + ".") }
            guard !mine.isEmpty else { continue }
            apps.append(App(bundleID: bundleID, name: running.localizedName ?? bundleID,
                            processes: mine.map(\.id), isPlaying: mine.contains { $0.isPlaying }))
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private struct ProcessObject { let id: AudioObjectID; let bundleID: String; let isPlaying: Bool }

    private static func processObjects() -> [ProcessObject] {
        var address = AudioOutputs.address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var bundleAddress = AudioOutputs.address(kAudioProcessPropertyBundleID)
            var bundleSize = UInt32(MemoryLayout<CFString?>.size)
            var bundle: Unmanaged<CFString>?
            guard AudioObjectGetPropertyData(id, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr,
                  let bundleID = bundle?.takeRetainedValue() as String?, !bundleID.isEmpty else { return nil }
            var runningAddress = AudioOutputs.address(kAudioProcessPropertyIsRunningOutput)
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(id, &runningAddress, 0, nil, &runningSize, &running)
            return ProcessObject(id: id, bundleID: bundleID, isPlaying: running != 0)
        }
    }

    static func uid(of device: AudioDeviceID) -> String? {
        var address = AudioOutputs.address(kAudioDevicePropertyDeviceUID)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var uid: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}

/// One app's sound, taken off the speakers and put back at a chosen level.
final class AppVolumeTap {
    /// Read on the audio thread, written on the main one. A torn read of a
    /// Float is not a thing on arm64, and a gain one buffer late is inaudible.
    final class Gain { var value: Float; init(_ value: Float) { self.value = value } }

    let gain: Gain
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    /// Nil when any step fails — most often the first time, before System
    /// Audio Recording has been allowed — and then nothing is left behind:
    /// the app keeps playing as it did.
    init?(name: String, processes: [AudioObjectID], outputUID: String, gain: Float) {
        self.gain = Gain(gain)

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        description.name = "Codenotch · \(name)"
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else {
            Log.usage.notice("app volume: tap refused for \(name, privacy: .public)")
            return nil
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Codenotch · \(name)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else {
            Log.usage.notice("app volume: no aggregate device for \(name, privacy: .public)")
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        let gainBox = self.gain
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
            Self.copy(from: input, to: output, gain: gainBox.value)
        }
        guard status == noErr, let procID, AudioDeviceStart(aggregateID, procID) == noErr else {
            Log.usage.notice("app volume: cannot start playback for \(name, privacy: .public)")
            stop()
            return nil
        }
    }

    deinit { stop() }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// The tap's stereo mix into whatever layout the output has: its first
    /// two channels take left and right, any others stay silent. Both sides
    /// are 32-bit float, which is what Core Audio hands an IOProc.
    static func copy(from input: UnsafePointer<AudioBufferList>,
                     to output: UnsafeMutablePointer<AudioBufferList>, gain: Float) {
        let sources = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let destinations = UnsafeMutableAudioBufferListPointer(output)

        // The usual case — one interleaved buffer each side — without a single
        // allocation: this runs on the real-time audio thread, where waiting
        // on the allocator is heard as a click.
        if sources.count == 1, destinations.count == 1,
           let source = sources[0].mData?.assumingMemoryBound(to: Float.self),
           let destination = destinations[0].mData?.assumingMemoryBound(to: Float.self) {
            let inChannels = max(1, Int(sources[0].mNumberChannels))
            let outChannels = max(1, Int(destinations[0].mNumberChannels))
            let inFrames = Int(sources[0].mDataByteSize) / MemoryLayout<Float>.size / inChannels
            let outFrames = Int(destinations[0].mDataByteSize) / MemoryLayout<Float>.size / outChannels
            for frame in 0..<outFrames {
                for channel in 0..<outChannels {
                    let sample: Float
                    if frame < inFrames, channel < max(2, inChannels) {
                        sample = source[frame * inChannels + min(channel, inChannels - 1)] * gain
                    } else {
                        sample = 0
                    }
                    destination[frame * outChannels + channel] = sample
                }
            }
            return
        }

        // The input's channels, in order, whichever way they are packed.
        var channels: [(data: UnsafePointer<Float>, stride: Int, frames: Int)] = []
        for buffer in sources {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = max(1, Int(buffer.mNumberChannels))
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / count
            for channel in 0..<count {
                channels.append((UnsafePointer(data + channel), count, frames))
            }
        }

        var outputChannel = 0
        for buffer in destinations {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = max(1, Int(buffer.mNumberChannels))
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / count
            for channel in 0..<count {
                let source = channels.isEmpty ? nil
                    : channels[min(outputChannel, channels.count - 1)]
                let feeds = outputChannel < max(2, channels.count) && source != nil
                for frame in 0..<frames {
                    data[frame * count + channel] = feeds && frame < source!.frames
                        ? source!.data[frame * source!.stride] * gain : 0
                }
                outputChannel += 1
            }
        }
    }
}

/// The per-app levels you have set, and the taps that apply them.
@MainActor
final class AppVolumeController {
    var onChange: (([AppAudio.App], [String: Float]) -> Void)?
    private(set) var apps: [AppAudio.App] = []
    /// By bundle id, 0…1. Absent means 100 %, untouched.
    private(set) var levels: [String: Float]
    private var taps: [String: AppVolumeTap] = [:]
    private var tappedWith: [String: (processes: [AudioObjectID], output: String)] = [:]
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.reload() }
    }
    private static let defaultsKey = "appVolumes"

    nonisolated init() {
        levels = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: Float] ?? [:]
    }

    func start() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioOutputs.address(selector)
            AudioObjectAddPropertyListenerBlock(system, &address, .main, listener)
        }
        reload()
    }

    /// Look again — which apps are playing changes without the process list
    /// changing, so the sound card asks when it opens.
    func reload() {
        apps = AppAudio.apps()
        applyTaps()
        onChange?(apps, levels)
    }

    func setLevel(_ level: Float, for bundleID: String) {
        let clamped = min(max(level, 0), 1)
        // Within a hair of full is full: the tap comes off, and the app is
        // back on its own path to the speakers.
        if clamped >= 0.99 { levels[bundleID] = nil } else { levels[bundleID] = clamped }
        UserDefaults.standard.set(levels, forKey: Self.defaultsKey)
        if let tap = taps[bundleID], let level = levels[bundleID] {
            tap.gain.value = level
        } else {
            applyTaps()
        }
        onChange?(apps, levels)
    }

    /// One tap per app with a level below full, rebuilt when its processes or
    /// the output change — a tap plays into one device, and a helper process
    /// started mid-call would otherwise play around it at full volume.
    private func applyTaps() {
        guard let output = AudioOutputs.defaultOutput(), let outputUID = AppAudio.uid(of: output) else { return }
        for (bundleID, tap) in taps {
            let app = apps.first { $0.bundleID == bundleID }
            let wanted = levels[bundleID] != nil && app != nil
            let current = tappedWith[bundleID]
            if !wanted || current?.processes != app?.processes || current?.output != outputUID {
                tap.stop()
                taps[bundleID] = nil
                tappedWith[bundleID] = nil
            }
        }
        for app in apps where taps[app.bundleID] == nil {
            guard let level = levels[app.bundleID] else { continue }
            if let tap = AppVolumeTap(name: app.name, processes: app.processes,
                                      outputUID: outputUID, gain: level) {
                taps[app.bundleID] = tap
                tappedWith[app.bundleID] = (app.processes, outputUID)
                Log.usage.info("app volume: \(app.name, privacy: .public) at \(Int(level * 100), privacy: .public)%")
            }
        }
    }
}

/// One line of the sound card's app section.
struct AppVolumeRow: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let isPlaying: Bool
    /// 0…1; 1 when untouched.
    let level: Float
    var id: String { bundleID }

    /// Call apps are listed whenever they are open, playing or not: the moment
    /// to turn Teams down is before the call, not while someone is talking.
    static let callApps: Set<String> = ["com.microsoft.teams2", "com.microsoft.teams",
                                         "us.zoom.xos", "com.tinyspeck.slackmacgap"]
    static let maxRows = 4

    /// What is worth a slider: an app playing now, an app you have already
    /// turned down, a call app. Call apps first, then the playing ones.
    static func rows(apps: [AppAudio.App], levels: [String: Float]) -> [AppVolumeRow] {
        apps
            .filter { $0.isPlaying || levels[$0.bundleID] != nil || callApps.contains($0.bundleID) }
            .map { AppVolumeRow(bundleID: $0.bundleID, name: $0.name, isPlaying: $0.isPlaying,
                                level: levels[$0.bundleID] ?? 1) }
            .sorted { a, b in
                let left = callApps.contains(a.bundleID), right = callApps.contains(b.bundleID)
                if left != right { return left }
                if a.isPlaying != b.isPlaying { return a.isPlaying }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            .prefix(maxRows)
            .map { $0 }
    }
}
