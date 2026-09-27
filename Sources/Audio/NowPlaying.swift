import AppKit
import Foundation

/// What is playing, and where — Spotify, or a YouTube tab in Chrome — with the
/// three buttons a player needs.
///
/// Each is driven through its own scripting interface rather than the system's
/// Now Playing: that one is private, closed to unentitled apps since macOS
/// 15.4, and could not say *which* player it would pause anyway.
struct NowPlaying: Identifiable, Equatable {
    enum Source: String, Equatable { case spotify, youtube }
    enum Command: Hashable { case toggle, next, previous }

    let source: Source
    let title: String
    let subtitle: String?
    let isPlaying: Bool
    /// False when the player can be seen but not steered: Chrome refuses to
    /// run a page's JavaScript for another app until you allow it.
    let isControllable: Bool
    /// Where a YouTube tab is, to steer that tab and no other.
    var chromeTab: (window: Int, index: Int)?

    var id: String { source.rawValue }

    static func == (a: NowPlaying, b: NowPlaying) -> Bool {
        a.source == b.source && a.title == b.title && a.subtitle == b.subtitle
            && a.isPlaying == b.isPlaying && a.isControllable == b.isControllable
            && a.chromeTab?.window == b.chromeTab?.window && a.chromeTab?.index == b.chromeTab?.index
    }
}

enum NowPlayingSources {
    static let spotifyID = "com.spotify.client"
    static let chromeID = "com.google.Chrome"

    /// Only an app that is already running is asked: a `tell` to one that is
    /// not would launch it, and nobody hovers a speaker to open Spotify.
    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func read() -> [NowPlaying] {
        [spotify(), youtube()].compactMap { $0 }
    }

    // MARK: - Spotify

    static func spotify() -> NowPlaying? {
        guard isRunning(spotifyID),
              let reply = osascript("""
                tell application id "\(spotifyID)"
                  if player state is stopped then return ""
                  return (player state as string) & linefeed & (name of current track) & linefeed & (artist of current track)
                end tell
                """), !reply.isEmpty
        else { return nil }
        let lines = reply.components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }
        return NowPlaying(source: .spotify, title: lines[1],
                          subtitle: lines.count > 2 && !lines[2].isEmpty ? lines[2] : nil,
                          isPlaying: lines[0] == "playing", isControllable: true)
    }

    // MARK: - YouTube in Chrome

    /// The YouTube tabs, the playing one first.
    ///
    /// The title comes from the tab and needs nothing; whether it is playing
    /// needs the page's `<video>`, which Chrome only lets another app read with
    /// View › Developer › Allow JavaScript from Apple Events switched on.
    static func youtube() -> NowPlaying? {
        guard isRunning(chromeID), let reply = osascript("""
            tell application id "\(chromeID)"
              set out to ""
              repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                  set i to i + 1
                  set u to URL of t
                  if u contains "youtube.com/watch" or u contains "music.youtube.com" or u contains "youtube.com/shorts" then
                    set videoState to "nojs"
                    try
                      set videoState to execute t javascript "(function(){var v=document.querySelector('video');return v?(v.paused?'paused':'playing'):'none'})()"
                    end try
                    set out to out & (id of w) & tab & i & tab & videoState & tab & (title of t) & linefeed
                  end if
                end repeat
              end repeat
              return out
            end tell
            """) else { return nil }
        let tabs = reply.split(separator: "\n").compactMap { line -> NowPlaying? in
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 4, let window = Int(fields[0]), let index = Int(fields[1]) else { return nil }
            let state = fields[2]
            return NowPlaying(source: .youtube, title: cleanTitle(fields[3...].joined(separator: "\t")),
                              subtitle: nil, isPlaying: state == "playing",
                              isControllable: state != "nojs",
                              chromeTab: (window, index))
        }
        return tabs.first { $0.isPlaying } ?? tabs.first
    }

    /// "(3) Some video - YouTube" → "Some video".
    static func cleanTitle(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("("), let close = text.firstIndex(of: ")") {
            let count = text[text.index(after: text.startIndex)..<close]
            if !count.isEmpty, count.allSatisfy(\.isNumber) {
                text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        for suffix in [" - YouTube Music", " - YouTube"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
        }
        return text
    }

    // MARK: - Steering

    static func send(_ command: NowPlaying.Command, to player: NowPlaying) {
        switch player.source {
        case .spotify:
            let verb: String
            switch command {
            case .toggle:   verb = "playpause"
            case .next:     verb = "next track"
            case .previous: verb = "previous track"
            }
            _ = osascript("tell application id \"\(spotifyID)\" to \(verb)")
        case .youtube:
            guard let tab = player.chromeTab else { return }
            let script: String
            switch command {
            case .toggle:
                script = "var v=document.querySelector('video');if(v){v.paused?v.play():v.pause()}"
            case .next:
                script = "var b=document.querySelector('.ytp-next-button, .next-button');if(b){b.click()}"
            case .previous:
                // YouTube has no "previous" outside a playlist; the start of
                // the video is what the button means everywhere else.
                script = "var b=document.querySelector('.ytp-prev-button:not([aria-disabled=true]), .previous-button');var v=document.querySelector('video');if(b&&b.offsetParent){b.click()}else if(v){v.currentTime=0}"
            }
            _ = osascript("""
                tell application id "\(chromeID)" to execute (tab \(tab.index) of window id \(tab.window)) javascript "\(script)"
                """)
        }
    }

    // MARK: -

    /// Through `osascript`, like the terminal tab focus: a subprocess, so a
    /// slow or hung app cannot stall the caller's thread past the timeout.
    private static func osascript(_ source: String) -> String? {
        TerminalTabFocus.run("/usr/bin/osascript", ["-e", source], timeout: 4)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Keeps the players current without polling them all day: Spotify announces
/// every change itself, and Chrome is asked when the sound card opens and after
/// each button — the only times anyone is looking.
@MainActor
final class NowPlayingMonitor {
    var onChange: (([NowPlaying]) -> Void)?
    private(set) var players: [NowPlaying] = []
    private var reading = false
    private var observer: NSObjectProtocol?

    nonisolated init() {}

    func start() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        guard !reading else { return }
        reading = true
        Task.detached(priority: .utility) {
            let players = NowPlayingSources.read()
            await MainActor.run {
                self.reading = false
                guard players != self.players else { return }
                self.players = players
                self.onChange?(players)
            }
        }
    }

    /// What a call paused, to be resumed when it ends — and nothing else: a
    /// player you had paused yourself stays paused.
    private var pausedForCall: [NowPlaying.Source] = []

    /// A call has started: pause whatever is playing.
    func pauseForCall() {
        Task.detached(priority: .userInitiated) {
            let playing = NowPlayingSources.read().filter { $0.isPlaying && $0.isControllable }
            for player in playing { NowPlayingSources.send(.toggle, to: player) }
            await MainActor.run {
                self.pausedForCall = playing.map(\.source)
                if !playing.isEmpty {
                    Log.usage.info("call started: paused \(playing.map(\.source.rawValue), privacy: .public)")
                }
                self.refresh()
            }
        }
    }

    /// The call is over: resume what it paused, if it is still paused.
    func resumeAfterCall() {
        let sources = pausedForCall
        pausedForCall = []
        guard !sources.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            // A moment for the call app to let go of the audio, so the music
            // does not come back under the hang-up tone.
            try? await Task.sleep(nanoseconds: 800_000_000)
            for player in NowPlayingSources.read()
            where sources.contains(player.source) && !player.isPlaying && player.isControllable {
                NowPlayingSources.send(.toggle, to: player)
            }
            await MainActor.run { self.refresh() }
        }
    }

    func send(_ command: NowPlaying.Command, to player: NowPlaying) {
        Task.detached(priority: .userInitiated) {
            NowPlayingSources.send(command, to: player)
            // The player takes a moment to settle — YouTube in particular has
            // to load the next video before its title changes.
            try? await Task.sleep(nanoseconds: 600_000_000)
            await MainActor.run { self.refresh() }
        }
    }
}
