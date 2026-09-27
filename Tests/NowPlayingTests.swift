import XCTest
@testable import Codenotch

/// What the sound card shows of the players.
final class NowPlayingTests: XCTestCase {
    func testAYouTubeTabTitleLosesItsCounterAndSuffix() {
        XCTAssertEqual(NowPlayingSources.cleanTitle("(3) Daft Punk - Veridis Quo - YouTube"),
                       "Daft Punk - Veridis Quo")
        XCTAssertEqual(NowPlayingSources.cleanTitle("Lo-fi beats - YouTube Music"), "Lo-fi beats")
        // A title that merely starts with a parenthesis keeps it.
        XCTAssertEqual(NowPlayingSources.cleanTitle("(Live) Concert - YouTube"), "(Live) Concert")
    }
}
