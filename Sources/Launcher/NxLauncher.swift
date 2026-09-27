import AppKit
import Foundation

/// What the notch's ▶ cell offers: the Nx workspaces your Wave terminals are
/// in, and a way to run any of their targets in a new block beside them.
///
/// Workspaces are found from the terminals, not configured: a workspace you
/// have a shell open in is one you are working on, and one you have not is
/// not worth a row. The one on the tab Wave is showing comes first.
@MainActor
final class NxLauncher {
    /// A workspace as the launcher lists it.
    struct Entry: Identifiable, Equatable {
        let workspace: NxWorkspace
        /// A terminal in it is on the tab Wave is showing.
        let isOnScreen: Bool
        var id: String { workspace.id }
    }

    /// Called with the current list whenever it changes.
    var onChange: (([Entry]) -> Void)?

    private(set) var entries: [Entry] = []
    private var graphs: [String: (loaded: Date, workspace: NxWorkspace)] = [:]
    private var refreshing = false

    /// Nonisolated so the app delegate can hold one from the start; nothing
    /// runs until `refresh`, which is on the main actor.
    nonisolated init() {}

    /// A graph older than this is read again on the next refresh. Targets
    /// change when a plugin or a config does, which is rare enough that the
    /// second a reload costs is better spent only now and then.
    nonisolated private static let graphLifetime: TimeInterval = 10 * 60

    /// Look at the terminals again, and at any graph that has gone stale.
    ///
    /// Cheap to call often — on every hover of the cell — because the process
    /// scan is fast and the graphs are cached; only a new or stale workspace
    /// costs an `nx graph`.
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let cached = graphs
        Task.detached(priority: .utility) {
            let blocks = WaveTerminal.liveBlocks()
            var roots: [String: URL] = [:]
            for live in blocks {
                if let root = NxWorkspace.root(containing: live.cwd) { roots[root.path] = root }
            }
            let onScreenTabs = Set(blocks.compactMap { $0.block.workspaceID }
                .compactMap(WaveTerminal.activeTab(inWorkspace:)))

            var loaded: [String: (loaded: Date, workspace: NxWorkspace)] = [:]
            for (path, root) in roots {
                if let held = cached[path], Date().timeIntervalSince(held.loaded) < Self.graphLifetime {
                    loaded[path] = held
                } else if let workspace = NxWorkspace.load(root: root) {
                    loaded[path] = (Date(), workspace)
                } else if let held = cached[path] {
                    // A failed reload keeps what worked last time.
                    loaded[path] = held
                }
            }
            let entries = loaded.values.map { held -> Entry in
                let onScreen = blocks.contains { live in
                    live.cwd.hasPrefix(held.workspace.root.path)
                        && live.block.tabID.map(onScreenTabs.contains) == true
                }
                return Entry(workspace: held.workspace, isOnScreen: onScreen)
            }
            .sorted { a, b in
                a.isOnScreen != b.isOnScreen ? a.isOnScreen
                    : a.workspace.name.localizedStandardCompare(b.workspace.name) == .orderedAscending
            }
            await MainActor.run {
                self.refreshing = false
                self.graphs = loaded
                guard entries != self.entries else { return }
                self.entries = entries
                self.onChange?(entries)
            }
        }
    }

    /// Run a target in a new Wave block, in the tab where you are already
    /// working on that workspace — then take you there to watch it.
    ///
    /// The tab chosen, best first: the one on screen with a terminal in the
    /// workspace, any tab with one, the tab on screen. The block is opened
    /// beside a terminal of that tab, because `wsh` puts a new block in the
    /// tab of the block whose credential it runs with.
    func launch(_ entry: Entry, project: String, target: String) {
        let workspace = entry.workspace
        let command = workspace.command(project: project, target: target)
        Log.usage.info("nx: \(command, privacy: .public) in \(workspace.name, privacy: .public)")
        Task.detached(priority: .userInitiated) {
            let blocks = WaveTerminal.liveBlocks()
            let onScreenTabs = Set(blocks.compactMap { $0.block.workspaceID }
                .compactMap(WaveTerminal.activeTab(inWorkspace:)))
            let isOnScreen = { (live: WaveTerminal.LiveBlock) in
                live.block.tabID.map(onScreenTabs.contains) == true
            }
            let inWorkspace = blocks.filter { $0.cwd.hasPrefix(workspace.root.path) }
            guard let beside = inWorkspace.first(where: isOnScreen) ?? inWorkspace.first
                    ?? blocks.first(where: isOnScreen) ?? blocks.first
            else {
                Log.usage.notice("nx: no Wave terminal to launch beside")
                return
            }
            guard WaveTerminal.run(command, cwd: workspace.root.path, beside: beside.block) else {
                Log.usage.notice("nx: wsh run failed")
                return
            }
            await Self.show(beside.block)
        }
    }

    /// Bring Wave forward on the tab the command was started in.
    private static func show(_ block: WaveTerminal.Block) async {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: WaveTerminal.bundleID).first
        else { return }
        _ = await SessionFocus.bringForward(app)
        guard let position = WaveTerminal.tabPosition(of: block), !position.isActive,
              position.index < 9, WaveTerminal.canSwitchTabs(prompt: true)
        else { return }
        WaveTerminal.switchToTab(number: position.index + 1)
    }
}
