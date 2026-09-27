import AppKit
import Foundation

/// Where a session is running, in the terms the switcher groups by.
///
/// A session knows its pid and nothing else (`AgentSession`), and the tooltip
/// never needed more: it shows one provider's sessions at a time, and they are
/// few. A list of *every* session at once does need more — nine Claude rows
/// with nothing to tell them apart is the problem the switcher exists to solve,
/// not a smaller copy of it.
///
/// Resolving one costs a walk up the process tree, and for Wave a subprocess,
/// so callers resolve off the main actor and hold the answer rather than asking
/// again per redraw.
struct SessionLocation: Equatable, Hashable {
    /// The application the session's process tree belongs to. Nil when the
    /// chain ran out before one appeared — an agent under launchd, or over ssh.
    let bundleID: String?
    /// What to call that application in a heading.
    let appName: String
    /// The Wave block this session sits in, when it sits in one.
    ///
    /// Held rather than re-derived: finding it reads the environment of every
    /// process between the agent and Wave, and both the jump and the badge want
    /// it again later.
    let wave: WaveTerminal.Block?
    /// The container inside the app, already in words a person reads — a Wave
    /// workspace's own name. Nil while unresolved, and for every terminal that
    /// names no container at all.
    let container: String?

    /// The group heading in the switcher.
    var heading: String {
        guard let container, !container.isEmpty else { return appName }
        return "\(appName) · \(container)"
    }

    /// Resolve from a pid, without naming the container.
    ///
    /// The naming is a second step because the list of workspace names is
    /// itself fetched with a block's own credential: nothing can name a
    /// workspace until at least one session has been located. The switcher
    /// resolves every session, then names them all in one pass — see
    /// `named(in:)`.
    static func resolve(pid: pid_t) -> SessionLocation {
        let app = SessionFocus.owningApp(of: pid)
        let bundleID = app?.bundleIdentifier
        return SessionLocation(
            bundleID: bundleID,
            // `localizedName` is what the Dock calls it, which is what the
            // person reading the heading has been looking at all day.
            appName: app?.localizedName ?? L10n.t("Terminal"),
            wave: bundleID == WaveTerminal.bundleID ? WaveTerminal.block(of: pid) : nil,
            container: nil
        )
    }

    /// The same location with its workspace resolved to a name.
    ///
    /// A block whose workspace is not in the list keeps a nil container rather
    /// than borrowing its id: Wave lists only workspaces that have a window
    /// open, and a bare UUID in a heading says less than nothing.
    func named(in workspaces: [String: WaveTerminal.Workspace]) -> SessionLocation {
        guard let id = wave?.workspaceID, let workspace = workspaces[id] else { return self }
        return SessionLocation(bundleID: bundleID, appName: appName,
                               wave: wave, container: workspace.name)
    }
}
