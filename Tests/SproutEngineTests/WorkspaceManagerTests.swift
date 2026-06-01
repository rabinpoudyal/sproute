import Testing
import Foundation
@testable import SproutEngine

private let repo = URL(fileURLWithPath: "/repo")

private struct AliveChecker: ProcessChecker {
    let alive: Set<Int32>
    func isAlive(pid: Int32) -> Bool { alive.contains(pid) }
}

private func makeManager(shell: FakeShellRunner, store: FakeStateStore,
                         fs: FakeFileSystem = FakeFileSystem(),
                         prober: PortProber,
                         checker: ProcessChecker = AliveChecker(alive: []),
                         terminator: FakeProcessTerminator = FakeProcessTerminator())
                         -> WorkspaceManager {
    let renderer = TemplateRenderer()
    return WorkspaceManager(
        git: GitService(shell: shell),
        portAllocator: PortAllocator(config: PortConfig(lower: 4000, upper: 4010),
                                     store: store, prober: prober),
        database: DatabaseService(shell: shell, renderer: renderer),
        envLinker: EnvLinker(fs: fs), fs: fs,
        setupRunner: SetupRunner(shell: shell, renderer: renderer),
        store: store, checker: checker, terminator: terminator,
        renderer: renderer, shell: shell
    )
}

private struct FreeProber: PortProber { func isFree(_ port: Int) -> Bool { true } }

@Test func createPersistsRunningRecordWithPortAndDB() async throws {
    let shell = FakeShellRunner()
    shell.handles = [("npm run dev", { FakeProcessHandle(pid: 900, exitCode: 0, lines: []) })]
    let store = FakeStateStore()
    let fs = FakeFileSystem(); fs.existing = ["/repo/.env"]
    let mgr = makeManager(shell: shell, store: store, fs: fs, prober: FreeProber())

    let rec = try await mgr.create(config: Fixtures.config(), repo: repo,
                                   base: "main", branch: "feature/login") { _ in }

    #expect(rec.port == 4000)
    #expect(rec.dbName == "shop_feature_login")
    #expect(rec.status == .running)
    #expect(rec.serverPID == 900)
    #expect(store.records.count == 1)
    // worktree created under baseDir/branch_slug
    #expect(rec.worktreePath == "/wt/feature_login")
    // env.local written
    #expect(fs.writes.contains { $0.path == "/wt/feature_login/.env.local" })
}

@Test func createRollsBackWhenSetupFails() async throws {
    let shell = FakeShellRunner()
    // make the migrate step fail
    shell.handles = [("npm run migrate", { FakeProcessHandle(pid: 1, exitCode: 1, lines: []) })]
    let store = FakeStateStore()
    let mgr = makeManager(shell: shell, store: store, prober: FreeProber())

    await #expect(throws: SetupError.self) {
        _ = try await mgr.create(config: Fixtures.config(), repo: repo,
                                 base: "main", branch: "feature/login") { _ in }
    }
    // rollback: record removed, drop + worktree remove issued
    #expect(store.records.isEmpty)
    let cmds = shell.calls.map(\.command)
    #expect(cmds.contains("dropdb --if-exists shop_feature_login"))
    #expect(cmds.contains("git worktree remove --force '/wt/feature_login'"))
}
