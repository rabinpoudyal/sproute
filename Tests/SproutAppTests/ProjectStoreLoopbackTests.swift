import Foundation
import Testing
import SproutEngine
@testable import SproutApp

@Suite struct ProjectStoreLoopbackTests {
    @Test func loopbackFileLivesUnderSproutRoot() {
        let url = SproutPaths.loopbackFile
        #expect(url.lastPathComponent == "loopback.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == ".sprout")
    }

    @Test @MainActor func activateProvisionsOncePerBranchRefcount() async throws {
        let prov = RecordingProvisioner()
        let store = makeLoopbackStore(
            prov: prov, enabled: true,
            processes: [ProcessConfig(name: "web", command: "true", port: 3000)])
        let rec = makeLoopbackRecord(branch: "feature/x", bindIP: "127.0.10.7")

        try await store.activateLoopback(rec)
        try await store.activateLoopback(rec)
        #expect(prov.calls.count == 1)
        #expect(
            prov.calls.first
                == .init(ip: "127.0.10.7", hosts: ["web.my-shop.localhost"], active: true))

        await store.deactivateLoopback(rec)
        await store.deactivateLoopback(rec)
        #expect(prov.calls.count == 2)
        #expect(
            prov.calls.last
                == .init(ip: "127.0.10.7", hosts: ["web.my-shop.localhost"], active: false))
    }

    @Test @MainActor func disabledSkipsProvisioning() async throws {
        let prov = RecordingProvisioner()
        let store = makeLoopbackStore(
            prov: prov, enabled: false,
            processes: [ProcessConfig(name: "web", command: "true", port: 3000)])
        let rec = makeLoopbackRecord(branch: "b", bindIP: "127.0.10.1")

        try await store.activateLoopback(rec)
        await store.deactivateLoopback(rec)
        #expect(prov.calls.isEmpty)
    }

    @Test @MainActor func activatePropagatesProvisionFailure() async {
        let prov = RecordingProvisioner()
        prov.setFailNext(true)
        let store = makeLoopbackStore(
            prov: prov, enabled: true,
            processes: [ProcessConfig(name: "web", command: "true", port: 3000)])
        let rec = makeLoopbackRecord(branch: "feature/x", bindIP: "127.0.10.7")

        await #expect(throws: ProvisionError.self) {
            try await store.activateLoopback(rec)
        }
        // Failed activate must not leave a refcount: a subsequent activate retries
        // (provisions again) rather than treating the branch as already active.
        prov.setFailNext(false)
        try? await store.activateLoopback(rec)
        #expect(prov.calls.filter { $0.active }.count == 2)
    }

    @Test @MainActor func allocateBindIPReturnsLoopbackIPWhenEnabled() async throws {
        let store = makeLoopbackStore(prov: RecordingProvisioner(), enabled: true, processes: [])
        let ip = try await store.allocateBindIP(branch: "feature/y")
        #expect(ip == "127.0.10.1")
    }

    @Test @MainActor func allocateBindIPReturnsLocalhostWhenDisabled() async throws {
        let store = makeLoopbackStore(prov: RecordingProvisioner(), enabled: false, processes: [])
        let ip = try await store.allocateBindIP(branch: "feature/y")
        #expect(ip == "127.0.0.1")
    }
}

/// Records every setActive call. `setFailNext(true)` makes the next call throw,
/// to test provision-failure handling. Lock-guarded so `calls` is readable from
/// `#expect` while `setActive` runs async.
final class RecordingProvisioner: LoopbackProvisioner, @unchecked Sendable {
    struct Call: Equatable { let ip: String; let hosts: [String]; let active: Bool }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _failNext = false

    var calls: [Call] { lock.withLock { _calls } }
    func setFailNext(_ value: Bool) { lock.withLock { _failNext = value } }

    func setActive(ip: String, hosts: [String], active: Bool) async throws {
        let shouldFail = lock.withLock { () -> Bool in
            let fail = _failNext
            _failNext = false
            _calls.append(Call(ip: ip, hosts: hosts, active: active))
            return fail
        }
        if shouldFail { throw ProvisionError.helperUnavailable }
    }
}

@MainActor
func makeLoopbackStore(
    prov: RecordingProvisioner,
    enabled: Bool,
    processes: [ProcessConfig],
    allocFile: URL? = nil
) -> ProjectStore {
    let config = Config(
        project: ProjectConfig(name: "My Shop"),
        worktree: WorktreeConfig(baseDir: "../wt", branchPrefix: "feature/"),
        env: EnvConfig(symlinkSources: [], localFile: ".env.local"),
        database: DatabaseConfig(
            createCommand: "createdb {{db_name}}",
            dropCommand: "dropdb {{db_name}}",
            urlTemplate: "postgres://localhost/{{db_name}}"),
        setup: [],
        run: RunConfig(processes: processes),
        hooks: HooksConfig())
    let tmpRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("sprout-ps-\(UUID().uuidString)")
    let alloc = IPAllocator(
        fileURL: allocFile ?? tmpRoot.appendingPathComponent("loopback.json"))
    return ProjectStore(
        rootURL: tmpRoot, config: config,
        loopbackEnabled: enabled,
        allocator: alloc,
        loopback: LoopbackCoordinator(provisioner: prov))
}

func makeLoopbackRecord(branch: String, bindIP: String) -> WorkspaceRecord {
    WorkspaceRecord(
        id: UUID(), branch: branch, base: "main",
        worktreePath: "/tmp/none", port: 3000, dbName: "db",
        status: .stopped, createdAt: Date(), processes: [], bindIP: bindIP)
}
