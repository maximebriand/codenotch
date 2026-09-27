import AudioToolbox
import XCTest
@testable import Codenotch

/// Per-app volume: which apps get a slider, and what the tap plays back.
final class AppVolumeTests: XCTestCase {
    private func app(_ id: String, playing: Bool) -> AppAudio.App {
        AppAudio.App(bundleID: id, name: id, processes: [], isPlaying: playing)
    }

    func testCallAppsComeFirstThenWhatIsPlaying() {
        let rows = AppVolumeRow.rows(apps: [
            app("com.spotify.client", playing: true),
            app("com.apple.Safari", playing: false),
            app("com.microsoft.teams2", playing: false),
            app("com.apple.Music", playing: false),
        ], levels: ["com.apple.Music": 0.3])

        XCTAssertEqual(rows.map(\.bundleID),
                       ["com.microsoft.teams2", "com.spotify.client", "com.apple.Music"],
                       "Safari is silent and untouched, so it gets no slider")
        XCTAssertEqual(rows.last?.level, 0.3)
        XCTAssertEqual(rows.first?.level, 1)
    }

    func testTheTapPlaysStereoIntoTheOutputScaled() {
        var input: [Float] = [1, -1, 0.5, -0.5]          // two stereo frames
        var output = [Float](repeating: 9, count: 8)      // two frames of four channels
        input.withUnsafeMutableBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                var inList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(4 * 4), mData: UnsafeMutableRawPointer(inPtr.baseAddress)))
                var outList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 4, mDataByteSize: UInt32(8 * 4), mData: UnsafeMutableRawPointer(outPtr.baseAddress)))
                AppVolumeTap.copy(from: &inList, to: &outList, gain: 0.5)
            }
        }
        XCTAssertEqual(output, [0.5, -0.5, 0, 0, 0.25, -0.25, 0, 0])
    }
}
