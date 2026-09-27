import AppKit
import SwiftUI

/// The switcher's window: a floating panel, opened by a global shortcut, that
/// lists every agent session and takes you to the one you pick.
///
/// A panel that takes the keyboard, unlike `NotchPanel`, which is
/// non-activating by construction — the notch must never steal focus from what
/// you are typing in. This is the opposite: you asked for it, and arrow keys
/// are the point.
@MainActor
final class SessionFleetWindowController: NSObject, NSWindowDelegate {
    private let model = SessionFleetViewModel()
    /// What the monitors currently publish, read at open and on every tick
    /// while open. A closure rather than a snapshot, for the same reason
    /// `SettingsWindowController` takes one: a list read once at launch is
    /// wrong by the time anybody looks at it.
    private let sessions: () -> [String: [AgentSession]]
    private var panel: FleetPanel?
    private var hotKey: GlobalHotKey?
    private var ticker: Timer?

    /// pid → where it runs. Resolving costs a walk up the process tree and, in
    /// Wave, a subprocess; a window can hold a session for hours, and asking
    /// again twice a second would spawn `wsh` twice a second.
    private var located: [pid_t: SessionLocation] = [:]
    /// Wave's workspace names, fetched once per opening. They change when
    /// somebody renames a workspace, which is not something worth polling for.
    private var workspaces: [String: WaveTerminal.Workspace] = [:]

    init(sessions: @escaping () -> [String: [AgentSession]]) {
        self.sessions = sessions
        super.init()
        model.onJump = { [weak self] row in self?.jump(to: row) }
    }

    /// Register the shortcut. Returns false when another application already
    /// holds that combination — the caller can say so rather than leaving a
    /// key that silently does nothing.
    @discardableResult
    func registerHotKey(keyCode: UInt32 = GlobalHotKey.defaultKeyCode,
                        modifiers: UInt32 = GlobalHotKey.defaultModifiers) -> Bool {
        hotKey = GlobalHotKey(keyCode: keyCode, modifiers: modifiers) { [weak self] in
            self?.toggle()
        }
        return hotKey != nil
    }

    func unregisterHotKey() { hotKey = nil }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        refresh()
        // The app is an ordinary Dock app, so bringing it forward is what makes
        // the panel able to take keystrokes at all.
        NSApp.activate()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        startTicking()
    }

    func hide() {
        stopTicking()
        panel?.orderOut(nil)
    }

    // MARK: - Contents

    private func refresh() {
        let live = sessions()
        let wanted = Set(live.values.flatMap { $0 }.compactMap(\.processID))
        // Windows that have closed since, so a long-lived panel does not hold a
        // location per terminal tab opened today.
        located = located.filter { wanted.contains($0.key) }

        let unknown = wanted.subtracting(located.keys)
        if !unknown.isEmpty {
            // Off the main actor: `SessionLocation.resolve` reads the process
            // tree and may run `wsh`, and doing that between two keystrokes is
            // what makes a panel feel stuck. What is already known is drawn
            // now; the rest fills in a moment later.
            Task.detached(priority: .userInitiated) { [weak self] in
                var found: [pid_t: SessionLocation] = [:]
                for pid in unknown { found[pid] = SessionLocation.resolve(pid: pid) }
                await self?.adopt(found)
            }
        }
        rebuild(live)
    }

    /// Newly resolved locations, plus the Wave workspace names they need.
    private func adopt(_ found: [pid_t: SessionLocation]) {
        located.merge(found) { _, new in new }
        // One block's credential is enough to ask about every workspace, and
        // until at least one session has been located there is nobody to ask —
        // which is why naming is a second pass. See `SessionLocation.named(in:)`.
        if workspaces.isEmpty, let block = located.values.compactMap(\.wave).first {
            let source = block
            Task.detached(priority: .utility) { [weak self] in
                let names = WaveTerminal.workspaces(as: source)
                await self?.adopt(workspaces: names)
            }
        }
        rebuild(sessions())
    }

    private func adopt(workspaces names: [String: WaveTerminal.Workspace]) {
        guard !names.isEmpty else { return }
        workspaces = names
        rebuild(sessions())
    }

    private func rebuild(_ live: [String: [AgentSession]]) {
        let workspaces = self.workspaces
        model.apply(SessionFleet.build(sessions: live) { [weak self] pid in
            self?.located[pid]?.named(in: workspaces)
        })
    }

    private func jump(to row: SessionFleet.Row) {
        guard let pid = row.session.processID else { return }
        hide()
        Task { _ = await SessionFocus.focus(pid: pid) }
    }

    // MARK: - The panel

    private func makePanel() -> FleetPanel {
        let panel = FleetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .fullSizeContentView, .closable],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        // Dismissed by switching away, like every other overlay: the panel
        // answers a question, and the answer is somewhere else.
        panel.hidesOnDeactivate = true
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: SessionFleetView(model: model, shortcut: Self.shortcutLabel)
        )
        panel.onKey = { [weak self] event in self?.handle(event) ?? false }
        panel.onCancel = { [weak self] in self?.hide() }
        return panel
    }

    /// True when the key was ours, so the panel does not also beep at it.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125: model.moveSelection(by: 1);  return true    // ↓
        case 126: model.moveSelection(by: -1); return true    // ↑
        case 36, 76:                                          // ↩ and the keypad's
            model.jumpToSelection()
            return true
        default: return false
        }
    }

    /// Spelled the way a menu would spell it, and only for display — the key is
    /// registered from `GlobalHotKey`'s own constants.
    static let shortcutLabel = "⌥⌘S"

    // MARK: - The clock

    /// The elapsed column is the one thing that changes while nothing else
    /// does, and only while somebody is looking at it.
    private func startTicking() {
        stopTicking()
        model.now = Date()
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.now = Date()
                self.refresh()
            }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    func windowWillClose(_ notification: Notification) { stopTicking() }
}

/// A panel that can take the keyboard.
///
/// `NSPanel` refuses to become key by default unless it is titled and visible
/// in the right ways; overriding says what this one is for outright, and the
/// two closures keep the AppKit half from needing to know about the model.
private final class FleetPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }

    /// Escape, and anything else macOS routes as a cancellation.
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
