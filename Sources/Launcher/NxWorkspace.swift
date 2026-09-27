import Foundation

/// An Nx workspace, as the notch's launcher offers it: its projects and what
/// each one can run.
///
/// Read from `nx graph`, not from the `project.json` files: most targets in a
/// modern workspace are inferred by plugins — `serve` from a Vite config,
/// `test` from Vitest, `component-test` from Cypress — and appear in no file
/// at all. The graph is the one place they are all written down, and with the
/// daemon warm it costs about a second.
struct NxWorkspace: Identifiable, Equatable {
    struct Project: Identifiable, Equatable {
        let name: String
        let isApp: Bool
        /// In the order the launcher shows them — see `NxWorkspace.ordered`.
        let targets: [String]
        var id: String { name }
    }

    /// The directory holding `nx.json`.
    let root: URL
    let projects: [Project]

    var id: String { root.path }
    var name: String { root.lastPathComponent }

    // MARK: - Finding one

    /// The workspace a directory belongs to: the nearest `nx.json` above it.
    ///
    /// Stops at the home directory, so a stray `nx.json` somewhere up the tree
    /// cannot claim every terminal on the machine.
    static func root(containing directory: String,
                     fileManager: FileManager = .default) -> URL? {
        let home = NSHomeDirectory()
        var url = URL(fileURLWithPath: directory).standardizedFileURL
        while url.path.hasPrefix(home), url.path != home {
            if fileManager.fileExists(atPath: url.appendingPathComponent("nx.json").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    // MARK: - Reading the graph

    /// Parse the file `nx graph --file` writes.
    ///
    /// Apps first, then libraries, each alphabetical. A project whose only
    /// targets are bookkeeping — `lint`, a release step — is left out: the
    /// launcher is for things you wait on and watch, and fifty `lint` rows
    /// would bury the three `serve`s.
    static func parse(graph data: Data, root: URL) -> NxWorkspace? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let graph = json["graph"] as? [String: Any],
              let nodes = graph["nodes"] as? [String: Any]
        else { return nil }

        var projects: [Project] = []
        for (name, raw) in nodes {
            guard let node = raw as? [String: Any],
                  let data = node["data"] as? [String: Any] else { continue }
            let targets = ((data["targets"] as? [String: Any]) ?? [:]).keys
            let useful = ordered(targets.filter { !quiet.contains($0) })
            guard !useful.isEmpty else { continue }
            projects.append(Project(name: name, isApp: node["type"] as? String == "app",
                                    targets: useful))
        }
        projects.sort { a, b in
            a.isApp != b.isApp ? a.isApp : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return NxWorkspace(root: root, projects: projects)
    }

    /// Targets nobody launches by hand from a menu.
    static let quiet: Set<String> = ["lint", "nx-release-publish", "typecheck", "format"]

    /// What you reach for first, first: running it, then testing it, then
    /// building it — and everything else after, alphabetically.
    static func ordered<S: Sequence>(_ targets: S) -> [String] where S.Element == String {
        let lead = ["serve", "dev", "start", "test", "component-test", "e2e", "build"]
        return targets.sorted { a, b in
            let left = lead.firstIndex(of: a) ?? lead.count
            let right = lead.firstIndex(of: b) ?? lead.count
            return left == right ? a.localizedStandardCompare(b) == .orderedAscending : left < right
        }
    }

    /// The command a target runs as, typed the way you would at the prompt.
    ///
    /// Through the workspace's own package manager, so the Nx it runs is the
    /// one in its lockfile rather than whatever happens to be global.
    func command(project: String, target: String, fileManager: FileManager = .default) -> String {
        let runner: String
        if fileManager.fileExists(atPath: root.appendingPathComponent("pnpm-lock.yaml").path) {
            runner = "pnpm exec nx"
        } else if fileManager.fileExists(atPath: root.appendingPathComponent("yarn.lock").path) {
            runner = "yarn nx"
        } else if fileManager.fileExists(atPath: root.appendingPathComponent("bun.lockb").path) {
            runner = "bunx nx"
        } else {
            runner = "npx nx"
        }
        return "\(runner) run \(project):\(target)"
    }

    // MARK: - Loading

    /// Ask the workspace's own Nx for its graph. Slow enough — a second warm,
    /// many cold — that callers run it off the main actor and cache the answer.
    static func load(root: URL) -> NxWorkspace? {
        let nx = root.appendingPathComponent("node_modules/.bin/nx")
        guard FileManager.default.isExecutableFile(atPath: nx.path) else {
            Log.usage.debug("nx: no local nx in \(root.lastPathComponent, privacy: .public)")
            return nil
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("codenotch-nx-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }

        let process = Process()
        process.executableURL = nx
        process.arguments = ["graph", "--file=\(output.path)"]
        process.currentDirectoryURL = root
        // `nx` starts with `#!/usr/bin/env node`, and an app Finder launched
        // has launchd's PATH, which has no Node in it. Homebrew's two prefixes
        // cover the machines this runs on; the rest of the environment is ours.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["NX_NO_CLOUD"] = "true"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.usage.debug("nx: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // A cold daemon on a large workspace can take a while; past this the
        // launcher shows what it had rather than wait on a stuck process.
        let deadline = Date().addingTimeInterval(60)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if process.isRunning { process.terminate(); return nil }
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: output) else {
            Log.usage.debug("nx: graph failed in \(root.lastPathComponent, privacy: .public)")
            return nil
        }
        return parse(graph: data, root: root)
    }
}
