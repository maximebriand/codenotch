import XCTest
@testable import Codenotch

/// The sound cell's view of Core Audio. Read-only against the real machine:
/// nothing here changes the output or the volume.
final class AudioOutputsTests: XCTestCase {
    func testTheCurrentOutputIsOneOfTheListedOnes() {
        let state = AudioOutputs.read()
        // A build machine may have no audio hardware at all; that is an
        // empty list, not a failure.
        guard let current = state.current, !state.devices.isEmpty else { return }
        XCTAssertTrue(state.devices.contains { $0.id == current },
                      "\(state.devices.map(\.name)) should hold the default output")
        if let volume = state.volume {
            XCTAssertTrue((0...1).contains(volume))
        }
    }

    func testEveryKindHasASymbol() {
        let kinds: [AudioOutputs.Device.Kind] = [.builtIn, .headphones, .display, .airPlay, .usb, .other]
        XCTAssertEqual(Set(kinds.map(\.symbol)).count, kinds.count)
    }
}
