// Compile harness only — never part of the app, never committed.
//
// Four files in Sources import Sparkle or SwiftNIO, and one uses the vendored
// zstd decoder through a bridging header; none of the three can be fed to
// `swiftc` without the package graph Xcode resolves. They are left out of the
// whole-module typecheck, and these stand in for the handful of symbols the
// remaining 193 files refer to across that seam.
import Foundation

enum PhoneLink { static let isAvailable = false }

enum PhoneLinkServerState: Equatable {
    case off
    case starting
    case ready(port: Int)
    case failed(String)
}

@MainActor
final class PhoneLinkServerStatus: ObservableObject {
    @Published var state: PhoneLinkServerState = .off
}

final class Updater: NSObject, ObservableObject {
    enum Outcome: Equatable {
        case idle, checking, upToDate(Date), found(String), unreachable, failed(String)
        var message: String? { nil }
    }
    @Published private(set) var outcome: Outcome = .idle
    var automatic: Bool = true
    var currentVersion: String = "0"
    var lastChecked: Date?
    func start() {}
    func checkNow() {}
}

/// Stands in for the NIO-backed server. Only its shape matters here.
final class PhoneLinkServer {
    init(pairing: PhoneLinkPairing,
         registry: PhoneLinkRegistry,
         status: PhoneLinkServerStatus? = nil,
         hostProvider: @escaping @Sendable () -> [String] = { [] },
         getSnapshot: @escaping @Sendable () async -> Data?,
         refreshAndGetSnapshot: @escaping @Sendable () async -> Data?) {}
    func start(port: Int = 8788) async throws -> Int { port }
    func stop() async {}
}

/// Stands in for the zstd-backed reader behind the bridging header.
struct ClaudeDesktopUsageCache: Sendable {
    struct Reading: Equatable, Sendable {
        let windows: [LimitWindow]
        let capturedAt: Date
        let entry: URL
        func isFresh(at now: Date = Date(), within window: TimeInterval) -> Bool { true }
    }
    init() {}
    func read(organization: String?) -> Reading? { nil }
}

/// Stands in for the NIO-backed Ollama relay.
final class OllamaRelayServer: @unchecked Sendable {
    typealias Observer = (UUID, String, Bool) -> Void
    init(upstream: URL,
         onPerformance: @escaping (String, LocalModelPerformance) -> Void = { _, _ in },
         observe: @escaping Observer) {}
    func start(port: Int = 11435) async throws -> Int { port }
    func stop() async {}
}
