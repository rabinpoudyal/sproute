import Testing
import Foundation
@testable import SproutEngine

private let repo = URL(fileURLWithPath: "/repo")

private struct AliveChecker: ProcessChecker {
    let alive: Set<Int32>
    func isAlive(pid: Int32) -> Bool { alive.contains(pid) }
}

private func makeManager(
    shell: FakeShellRunner, store: FakeStateStore,
    fs: FakeFileSystem = FakeFileSystem(),
    prober: PortProber,
    checker: ProcessChecker = AliveChecker(alive: []),
    terminator: FakeProcessTerminator = FakeProcessTerminator()
)
    -> WorkspaceManager
{
    let renderer = TemplateRenderer()
    return WorkspaceManager(
        git: GitService(shell: shell),
        portAllocator: PortAllocator(
            config: PortConfig(lower: 4000, upper: 4010),
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

    let rec = try await mgr.create(
        config: Fixtures.config(), repo: repo,
        base: "main", branch: "feature/login"
    ) { _ in }

    #expect(rec.port == 4000)
    #expect(rec.dbName == "shop_feature_login")
    #expect(rec.status == .running)
    #expect(rec.processes == [ProcessState(name: "server", pid: 900, status: .running)])
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
        _ = try await mgr.create(
            config: Fixtures.config(), repo: repo,
            base: "main", branch: "feature/login"
        ) { _ in }
    }
    // rollback: record removed, drop + worktree remove issued
    #expect(store.records.isEmpty)
    let cmds = shell.calls.map(\.command)
    #expect(cmds.contains("dropdb --if-exists shop_feature_login"))
    #expect(cmds.contains("git worktree remove --force '/wt/feature_login'"))
}

@Test func createRollbackDeletesBranchPrunesAndRemovesLeftoverDir() async throws {
    let shell = FakeShellRunner()
    shell.handles = [("npm run migrate", { FakeProcessHandle(pid: 1, exitCode: 1, lines: []) })]
    let store = FakeStateStore()
    // worktree dir lingers after `git worktree remove` (simulates a partial/failed add)
    let fs = FakeFileSystem(); fs.existing = ["/wt/feature_login"]
    let mgr = makeManager(shell: shell, store: store, fs: fs, prober: FreeProber())

    await #expect(throws: SetupError.self) {
        _ = try await mgr.create(
            config: Fixtures.config(), repo: repo,
            base: "main", branch: "feature/login"
        ) { _ in }
    }
    let cmds = shell.calls.map(\.command)
    #expect(cmds.contains("git worktree remove --force '/wt/feature_login'"))
    #expect(cmds.contains("git worktree prune"))
    #expect(cmds.contains("git branch -D 'feature/login'"))  // -b created it; clean for retry
    #expect(fs.removed.contains("/wt/feature_login"))  // leftover dir force-removed
    #expect(store.records.isEmpty)
}

@Test func createRollbackTerminatesAlreadyStartedProcessesOnPartialFailure() async throws {
    // Build a two-process config: "web" starts fine, "worker" fails to launch.
    var twoProcessConfig = Fixtures.config()
    twoProcessConfig.setup = []
    twoProcessConfig.run = RunConfig(
        processes: [
            ProcessConfig(name: "web", command: "npm run web"),
            ProcessConfig(name: "worker", command: "npm run worker"),
        ])
    let shell = FakeShellRunner()
    // "web" launches successfully with pid 777; "worker" launch throws.
    shell.handles = [("npm run web", { FakeProcessHandle(pid: 777, exitCode: 0, lines: []) })]
    shell.throwOnLaunch = ["npm run worker"]
    let store = FakeStateStore()
    let term = FakeProcessTerminator()
    let mgr = makeManager(shell: shell, store: store, prober: FreeProber(), terminator: term)

    await #expect(throws: (any Error).self) {
        _ = try await mgr.create(
            config: twoProcessConfig, repo: repo,
            base: "main", branch: "feature/login"
        ) { _ in }
    }
    // The first process (pid 777) must have been terminated during rollback.
    #expect(term.terminated.contains(777))
    // No record should persist.
    #expect(store.records.isEmpty)
}

private func seedRecord(into store: FakeStateStore, pid: Int32? = 900) -> WorkspaceRecord {
    let procs = pid.map { [ProcessState(name: "server", pid: $0, status: .running)] } ?? []
    let r = WorkspaceRecord(
        id: UUID(), branch: "feature/login", base: "main",
        worktreePath: "/wt/feature_login", port: 4000, dbName: "shop_feature_login",
        status: .running, createdAt: Date(), processes: procs)
    store.records = [r]
    return r
}

@Test func teardownWithPushRunsFullOrderAndClearsState() async throws {
    let shell = FakeShellRunner()
    shell.runResults = [("status --porcelain", ProcessResult(stdout: "", stderr: "", exitCode: 0))]
    let store = FakeStateStore()
    let term = FakeProcessTerminator()
    let r = seedRecord(into: store)
    let mgr = makeManager(shell: shell, store: store, prober: FreeProber(), terminator: term)

    try await mgr.teardown(
        id: r.id, config: Fixtures.config(), repo: repo,
        push: true, force: false)

    let cmds = shell.calls.map(\.command)
    #expect(cmds.contains("git push -u origin 'feature/login'"))
    #expect(cmds.contains("dropdb --if-exists shop_feature_login"))
    #expect(cmds.contains("git worktree remove --force '/wt/feature_login'"))
    #expect(cmds.contains("git branch -D 'feature/login'"))
    #expect(term.terminated == [900])
    #expect(store.records.isEmpty)
}

@Test func teardownAbortsWhenDirtyAndNotForced() async {
    let shell = FakeShellRunner()
    shell.runResults = [
        (
            "status --porcelain",
            ProcessResult(stdout: " M f\n", stderr: "", exitCode: 0)
        )
    ]
    let store = FakeStateStore()
    let r = seedRecord(into: store)
    let mgr = makeManager(shell: shell, store: store, prober: FreeProber())

    await #expect(throws: TeardownError.self) {
        try await mgr.teardown(
            id: r.id, config: Fixtures.config(), repo: repo,
            push: true, force: false)
    }
    // record still present, no destructive commands ran
    #expect(store.records.count == 1)
    #expect(!shell.calls.map(\.command).contains("git push -u origin 'feature/login'"))
}

@Test func discardSkipsPushAndDirtyCheck() async throws {
    let shell = FakeShellRunner()
    // dirty, but discard must ignore it
    shell.runResults = [
        (
            "status --porcelain",
            ProcessResult(stdout: " M f\n", stderr: "", exitCode: 0)
        )
    ]
    let store = FakeStateStore()
    let term = FakeProcessTerminator()
    let r = seedRecord(into: store)
    let mgr = makeManager(shell: shell, store: store, prober: FreeProber(), terminator: term)

    try await mgr.teardown(
        id: r.id, config: Fixtures.config(), repo: repo,
        push: false, force: false)

    let cmds = shell.calls.map(\.command)
    #expect(!cmds.contains("git push -u origin 'feature/login'"))
    #expect(cmds.contains("dropdb --if-exists shop_feature_login"))
    #expect(store.records.isEmpty)
}

@Test func reconcileMarksDeadPidStopped() throws {
    let shell = FakeShellRunner()
    let store = FakeStateStore()
    let fs = FakeFileSystem(); fs.existing = ["/wt/feature_login"]
    _ = seedRecord(into: store, pid: 900)  // pid 900 not alive
    let mgr = makeManager(
        shell: shell, store: store, fs: fs, prober: FreeProber(),
        checker: AliveChecker(alive: []))
    let result = try mgr.reconcile()
    #expect(result.first?.status == .stopped)
    #expect(store.records.first?.status == .stopped)
    #expect(result.first?.orphaned == false)
}

@Test func reconcileKeepsRunningWhenPidAlive() throws {
    let shell = FakeShellRunner()
    let store = FakeStateStore()
    let fs = FakeFileSystem(); fs.existing = ["/wt/feature_login"]
    _ = seedRecord(into: store, pid: 900)
    let mgr = makeManager(
        shell: shell, store: store, fs: fs, prober: FreeProber(),
        checker: AliveChecker(alive: [900]))
    let result = try mgr.reconcile()
    #expect(result.first?.status == .running)
}

@Test func reconcileFlagsMissingWorktreeAsOrphaned() throws {
    let shell = FakeShellRunner()
    let store = FakeStateStore()
    let fs = FakeFileSystem(); fs.existing = []  // worktree gone
    _ = seedRecord(into: store, pid: nil)
    let mgr = makeManager(
        shell: shell, store: store, fs: fs, prober: FreeProber(),
        checker: AliveChecker(alive: []))
    let result = try mgr.reconcile()
    #expect(result.first?.orphaned == true)
}
