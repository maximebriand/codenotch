import XCTest
@testable import Codenotch

/// The notch's Nx launcher: what it reads from a workspace's graph, and how it
/// finds its way to the right Wave tab.
final class NxLauncherTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/ws")

    private func graph(_ nodes: [String: (type: String, targets: [String])]) -> Data {
        var json: [String: Any] = [:]
        for (name, node) in nodes {
            json[name] = ["type": node.type,
                          "data": ["targets": Dictionary(uniqueKeysWithValues: node.targets.map { ($0, [:]) })]]
        }
        return try! JSONSerialization.data(withJSONObject: ["graph": ["nodes": json]])
    }

    func testAppsComeFirstAndLintOnlyProjectsAreLeftOut() {
        let workspace = NxWorkspace.parse(graph: graph([
            "shared-utils": ("lib", ["build", "lint", "test"]),
            "ext-core-auth": ("lib", ["lint"]),
            "ext-ouestcebien": ("app", ["zip", "lint", "build", "serve", "test", "build:chrome"]),
        ]), root: root)

        XCTAssertEqual(workspace?.projects.map(\.name), ["ext-ouestcebien", "shared-utils"])
        XCTAssertEqual(workspace?.projects.first?.targets, ["serve", "test", "build", "build:chrome", "zip"])
    }

    func testWhatYouRunComesBeforeWhatYouBuild() {
        XCTAssertEqual(NxWorkspace.ordered(["build", "e2e", "component-test", "test", "dev", "zip"]),
                       ["dev", "test", "component-test", "e2e", "build", "zip"])
    }

    func testTheCommandGoesThroughTheWorkspacesOwnNx() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = NxWorkspace(root: directory, projects: [])
        XCTAssertEqual(workspace.command(project: "api", target: "serve"), "npx nx run api:serve")

        FileManager.default.createFile(atPath: directory.appendingPathComponent("pnpm-lock.yaml").path,
                                       contents: Data())
        XCTAssertEqual(workspace.command(project: "api", target: "serve"), "pnpm exec nx run api:serve")
    }

    func testAWorkspaceIsFoundFromAnywhereInside() throws {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let directory = home.appendingPathComponent(".codenotch-nx-test-\(UUID().uuidString)")
        let deep = directory.appendingPathComponent("apps/web/src")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        FileManager.default.createFile(atPath: directory.appendingPathComponent("nx.json").path,
                                       contents: Data("{}".utf8))

        XCTAssertEqual(NxWorkspace.root(containing: deep.path)?.standardizedFileURL.path,
                       directory.standardizedFileURL.path)
        XCTAssertNil(NxWorkspace.root(containing: home.path))
    }

    func testATabsPositionIsItsPlaceInTheBar() {
        let json = Data(#"{"tabids":["a","b","c"],"activetabid":"b"}"#.utf8)
        XCTAssertEqual(WaveTerminal.tabPosition(of: "c", inWorkspaceJSON: json),
                       WaveTerminal.TabPosition(index: 2, isActive: false))
        XCTAssertEqual(WaveTerminal.tabPosition(of: "b", inWorkspaceJSON: json),
                       WaveTerminal.TabPosition(index: 1, isActive: true))
        XCTAssertNil(WaveTerminal.tabPosition(of: "z", inWorkspaceJSON: json))
    }
}
