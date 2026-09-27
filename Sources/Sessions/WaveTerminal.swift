import ApplicationServices
import Darwin
import Foundation
import SQLite3

/// Wave's side of exact-tab focus.
///
/// Wave publishes no scripting dictionary and registers no URL scheme, so the
/// only way in is `wsh`, the CLI it installs beside itself. `wsh` reaches the
/// Wave server over a unix socket and authenticates with a JWT it reads from
/// its own environment — and refuses to start without one:
///
///     wsh must be run inside a Wave-managed SSH session (WAVETERM_JWT not found)
///
/// Codenotch is never inside a Wave block, so it borrows the credential from
/// the session it is being asked about. Every process Wave spawns inherits
/// `WAVETERM_JWT` and `WAVETERM_BLOCKID`, and an agent started at such a prompt
/// still carries both — the same trick `TerminalTabFocus` already plays with
/// cmux's `CMUX_SURFACE_ID`. Those two variables are enough to read and write
/// blocks in any tab of any workspace, checked against a stripped environment.
///
/// `focusblock` wants a third, `WAVETERM_TABID`, and refuses without it: it
/// looks the block up inside that tab. The block's own tab is passed, which is
/// what lets it find the block at all. Should Wave still refuse — a Wave that
/// scopes the lookup to the tab on screen — the session gets a badge instead:
/// its tab lights up in Wave's tab bar and one click finishes the journey.
enum WaveTerminal {
    static let bundleID = "dev.commandline.waveterm"

    /// Where a session lives in Wave, and the credential to ask about it.
    struct Block: Equatable, Hashable {
        let id: String
        /// Nil for a Wave old enough not to publish it. Only ever used to tell
        /// two sessions apart in the switcher's grouping, never to address one.
        let tabID: String?
        let workspaceID: String?
        /// `wsh`'s bearer token, signed by the server and carrying the block it
        /// was issued for. Read from the same process as `id` for that reason —
        /// see `block(inEnvironment:)`.
        let jwt: String
    }

    /// The Wave block a process runs in, found by walking up its ancestry.
    ///
    /// Up the tree rather than at the process itself because a wrapper — a
    /// version manager, a `npx` shim — occasionally starts the agent with a
    /// scrubbed environment while the shell above it kept the full one.
    static func block(of pid: pid_t) -> Block? {
        for candidate in SessionFocus.ancestry(of: pid) {
            if let block = block(inEnvironment: TerminalTabFocus.environment(of: candidate)) {
                return block
            }
        }
        return nil
    }

    /// Both halves or nothing.
    ///
    /// `wsh` needs the token *and* a block id to resolve against, and a pair
    /// assembled from two different processes could name a block the token was
    /// never issued for — which the server answers by refusing, at the moment
    /// somebody is waiting to be taken to their session.
    static func block(inEnvironment entries: [String]) -> Block? {
        var values: [String: String] = [:]
        for entry in entries {
            // A process's environment block is thousands of entries wide and
            // this runs per ancestor per focus; the prefix check is what keeps
            // it from splitting all of them.
            guard entry.hasPrefix("WAVETERM"), let separator = entry.firstIndex(of: "=")
            else { continue }
            values[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        /// Wave exports `WAVETERM_CONN=` empty for a local block, so presence
        /// is not the same as having a value anywhere in here.
        let value: (String) -> String? = { key in
            guard let found = values[key], !found.isEmpty else { return nil }
            return found
        }
        guard let id = value("WAVETERM_BLOCKID"), let jwt = value("WAVETERM_JWT") else { return nil }
        return Block(id: id, tabID: value("WAVETERM_TABID"),
                     workspaceID: value("WAVETERM_WORKSPACEID"), jwt: jwt)
    }

    /// Where Wave installs `wsh`.
    ///
    /// Spelled out rather than looked up on `PATH`: a GUI app inherits launchd's
    /// login `PATH`, and Wave's bin directory gets there through the shell
    /// profile it writes — which no app Finder launched has ever read.
    static var cliURL: URL? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/waveterm/bin/wsh")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Select the block, when it happens to be in the tab Wave is already on.
    ///
    /// False is the ordinary answer for a session anywhere else — `wsh` exits
    /// non-zero and `run` reports nil — and the caller is expected to treat it
    /// as "show me where it is" rather than as an error.
    @discardableResult
    static func focus(_ block: Block) -> Bool {
        run(["focusblock", "-b", block.id], as: block) != nil
    }

    /// Mark the block so its tab stands out in Wave's tab bar.
    ///
    /// `clearingWhenPIDExits` hands the lifetime to Wave: the badge goes when
    /// the agent does, so a session that ends while you are in another
    /// workspace leaves no mark for Codenotch to remember to clean up — including
    /// across a Codenotch restart, which it would otherwise have no record of.
    @discardableResult
    static func badge(_ block: Block, icon: String, color: String,
                      clearingWhenPIDExits pid: pid_t? = nil) -> Bool {
        var arguments = ["badge", "-b", block.id, icon, "--color", color]
        if let pid { arguments += ["--pid", String(pid)] }
        return run(arguments, as: block) != nil
    }

    /// The mark a session blocked on a question leaves on its block.
    ///
    /// Wave takes an icon name from its own set and a colour. The colour is the
    /// yellow `Palette.watch` paints a waiting session in the notch, so a badge
    /// in Wave's tab bar and a row in the notch say the same thing in the same
    /// hue. The icon name is Wave's to validate — it accepts anything and shows
    /// nothing for a name it does not know, so this one wants an eye on it
    /// after any change.
    static let blockedBadgeIcon = "bell"
    static let blockedBadgeColor = "#F2FF00"

    @discardableResult
    static func clearBadge(_ block: Block) -> Bool {
        run(["badge", "-b", block.id, "--clear"], as: block) != nil
    }

    // MARK: - Switching tabs

    /// Where a block's tab sits in its workspace's tab bar, and whether it is
    /// the one on screen.
    ///
    /// Read from Wave's own database, because nothing Wave exposes answers it:
    /// `wsh` has no tab listing and its RPC no tab switch. The workspace row
    /// holds the tab order exactly as the bar draws it — `tabids`, the same list
    /// Wave's own ⌘1…⌘9 index into — and the active tab beside it.
    struct TabPosition: Equatable {
        /// Zero-based, as in `tabids`.
        let index: Int
        let isActive: Bool
    }

    static var databaseURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/waveterm/db/waveterm.db")
    }

    static func tabPosition(of block: Block) -> TabPosition? {
        guard let tab = block.tabID, let workspace = block.workspaceID,
              let db = SQLiteStore.open(databaseURL) else { return nil }
        defer { sqlite3_close(db) }
        guard let json = SQLiteStore.rows(in: db, sql: "SELECT data FROM db_workspace WHERE oid = ?",
                                          bind: workspace).first,
              let data = json.data(using: .utf8) else { return nil }
        return tabPosition(of: tab, inWorkspaceJSON: data)
    }

    static func tabPosition(of tab: String, inWorkspaceJSON data: Data) -> TabPosition? {
        guard let workspace = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tabs = workspace["tabids"] as? [String],
              let index = tabs.firstIndex(of: tab) else { return nil }
        return TabPosition(index: index, isActive: workspace["activetabid"] as? String == tab)
    }

    /// Whether Codenotch may send Wave the keystroke that switches tabs.
    ///
    /// Posting a keystroke to another app is what Accessibility permission
    /// guards. `prompt` asks macOS to show its dialog — once, from the first
    /// jump that needs it; after that the setting lives in System Settings.
    static func canSwitchTabs(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Press ⌘1…⌘9 in Wave, which must already be frontmost.
    ///
    /// Wave matches the binding on the *character*, not the key, so the event
    /// carries the digit itself: on an AZERTY keyboard the key in that
    /// position types "&", and a bare key code would switch nothing.
    @discardableResult
    static func switchToTab(number: Int) -> Bool {
        guard (1...9).contains(number) else { return false }
        // The ANSI key codes for 1…9 — irregular, as the hardware is.
        let keyCodes: [CGKeyCode] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]
        let source = CGEventSource(stateID: .hidSystemState)
        var digit = Array(String(number).utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source,
                                      virtualKey: keyCodes[number - 1], keyDown: down)
            else { return false }
            event.flags = .maskCommand
            event.keyboardSetUnicodeString(stringLength: digit.count, unicodeString: &digit)
            event.post(tap: .cghidEventTap)
        }
        return true
    }

    // MARK: - Terminals that are open

    /// A Wave terminal and the directory its shell is in right now.
    struct LiveBlock: Equatable {
        let block: Block
        let cwd: String
    }

    /// Every Wave terminal with a shell running in it.
    ///
    /// Found from the processes, not from Wave: every process in a block
    /// carries the block's id and credential, and the shell's own working
    /// directory is where you actually `cd`'d to — Wave's `cmd:cwd` is only
    /// where the block started. One process per block, the oldest, which is
    /// the shell everything else in the block was started from.
    static func liveBlocks() -> [LiveBlock] {
        var oldest: [String: (pid: pid_t, block: Block)] = [:]
        for pid in allProcessIDs() {
            guard let block = block(inEnvironment: TerminalTabFocus.environment(of: pid)) else { continue }
            if let held = oldest[block.id], held.pid < pid { continue }
            oldest[block.id] = (pid, block)
        }
        return oldest.values.compactMap { entry in
            SessionFocus.currentDirectory(of: entry.pid).map { LiveBlock(block: entry.block, cwd: $0) }
        }
    }

    private static func allProcessIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Room to spare: processes start between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        let mine = getuid()
        return pids.prefix(Int(filled)).filter { pid in
            guard pid > 1 else { return false }
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            return proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size
                && info.pbsi_uid == mine
        }
    }

    /// The tab Wave shows for a workspace, read from its database.
    static func activeTab(inWorkspace workspace: String) -> String? {
        guard let db = SQLiteStore.open(databaseURL) else { return nil }
        defer { sqlite3_close(db) }
        guard let json = SQLiteStore.rows(in: db, sql: "SELECT data FROM db_workspace WHERE oid = ?",
                                          bind: workspace).first,
              let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return object["activetabid"] as? String
    }

    /// Run a command in a new block beside `block`, in the same tab.
    ///
    /// The block stays open when the command ends, so a failed test run or a
    /// server's last words are still there to read.
    @discardableResult
    static func run(_ command: String, cwd: String, beside block: Block) -> Bool {
        run(["run", "--cwd", cwd, "-c", command], as: block) != nil
    }

    /// An open Wave workspace, as its own tab bar names it.
    struct Workspace: Equatable {
        let id: String
        let name: String
        /// Wave's accent for this workspace, `#rrggbb`. Carried so a group
        /// heading in the switcher can read the colour it already has in Wave's
        /// sidebar, rather than inventing a second scheme for the same thing.
        let color: String?
    }

    /// The open workspaces, keyed by the id a block reports.
    ///
    /// Only the open ones: `wsh` lists workspaces by the window showing them,
    /// so one closed since is absent — correctly, since no session can be
    /// running in a workspace nobody has on screen.
    static func workspaces(as block: Block) -> [String: Workspace] {
        guard let output = run(["workspace", "list"], as: block),
              let data = output.data(using: .utf8)
        else { return [:] }
        return workspaces(fromJSON: data)
    }

    static func workspaces(fromJSON data: Data) -> [String: Workspace] {
        struct Wire: Decodable {
            let workspaceId: String
            let name: String?
            let color: String?
        }
        guard let rows = try? JSONDecoder().decode([Wire].self, from: data) else {
            Log.sessions.notice("wave: unreadable workspace list")
            return [:]
        }
        var found: [String: Workspace] = [:]
        for row in rows {
            // A workspace with no name of its own is Wave's unnamed default,
            // and an id in a heading would say less than nothing.
            guard let name = row.name, !name.isEmpty else { continue }
            found[row.workspaceId] = Workspace(id: row.workspaceId, name: name, color: row.color)
        }
        return found
    }

    /// `wsh`, run with exactly the two variables it insists on.
    ///
    /// A whole inherited environment is deliberately not passed through:
    /// Codenotch's own is a launchd environment with nothing Wave wants in it,
    /// and handing a subprocess more than it needs is how a surprise gets in.
    private static func run(_ arguments: [String], as block: Block) -> String? {
        guard let cli = cliURL else {
            Log.sessions.debug("wave: no wsh installed")
            return nil
        }
        var environment = [
            "WAVETERM_JWT": block.jwt,
            "WAVETERM_BLOCKID": block.id
        ]
        // `focusblock` resolves its block inside the caller's tab and refuses
        // outright without one: "no tab id specified". Handing over the
        // block's own tab is what makes the block findable at all.
        if let tab = block.tabID { environment["WAVETERM_TABID"] = tab }
        return TerminalTabFocus.run(cli.path, arguments, environment: environment)
    }
}
