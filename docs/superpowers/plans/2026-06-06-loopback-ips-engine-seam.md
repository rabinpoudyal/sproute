# Per-Workspace Loopback IPs — Engine Seam Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the engine-side foundation for per-workspace loopback IPs — IP allocation, `{{host}}` templating, a `bindIP` on each workspace record, a reference-counted provision coordinator behind a protocol seam — all unit-tested with no root and no app bundle, and non-breaking (everything defaults to `127.0.0.1`).

**Architecture:** New engine types (`IPAllocator`, `LoopbackProvisioner` protocol + `NoopLoopbackProvisioner`, `LoopbackCoordinator`) plus a `host` field threaded through `TemplateContext`/`TemplateRenderer`, `WorkspaceRecord`, and `WorkspaceManager.create`. The real privileged provisioner (XPC helper) and the wiring that hands out real `127.0.10.x` addresses are out of scope here — they land in the follow-up plan (`2026-06-06-loopback-ips-helper-and-bundling.md`). Because `bindIP` defaults to `127.0.0.1` and the wired provisioner is the no-op, runtime behavior is unchanged after this plan.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing (`import Testing`, `@Test`, `#expect`), SwiftPM. Engine code in `Sources/SproutEngine/`, tests in `Tests/SproutEngineTests/`.

**Reference spec:** `docs/superpowers/specs/2026-06-06-per-workspace-loopback-ips-design.md`

**Conventions reminder:** 4-space indent, ~100 col soft limit, typed error enums per module, DI via protocols with fakes in `Tests/SproutEngineTests/Support/`. Run `swift build` and `swift test` after each task (the pre-commit hook runs lint + build + test).

---

### Task 1: IPAllocator + LoopbackError

A persisted, global, sequential allocator mapping `(project, branch)` to `127.0.10.N`, reusing freed slots. Persists its own JSON file (Foundation file IO, like `JSONStateStore`), so it does not need the `FileSystem` protocol (which has no read method). Tests inject a temp file URL.

**Files:**
- Create: `Sources/SproutEngine/Port/IPAllocator.swift`
- Test: `Tests/SproutEngineTests/IPAllocatorTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SproutEngineTests/IPAllocatorTests.swift`:

```swift
import Testing
import Foundation
@testable import SproutEngine

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("sprout-loopback-\(UUID().uuidString).json")
}

@Test func allocateAssignsSequentialFromBase() async throws {
    let a = IPAllocator(fileURL: tempFile())
    #expect(try await a.allocate(project: "shop", branch: "main") == "127.0.10.1")
    #expect(try await a.allocate(project: "shop", branch: "feature/login") == "127.0.10.2")
}

@Test func allocateIsIdempotentPerProjectBranch() async throws {
    let a = IPAllocator(fileURL: tempFile())
    let first = try await a.allocate(project: "shop", branch: "main")
    let again = try await a.allocate(project: "shop", branch: "main")
    #expect(first == again)
}

@Test func releaseFreesSlotForReuse() async throws {
    let a = IPAllocator(fileURL: tempFile())
    _ = try await a.allocate(project: "shop", branch: "main")          // .1
    _ = try await a.allocate(project: "shop", branch: "feature/login") // .2
    try await a.release(project: "shop", branch: "main")               // frees .1
    // lowest-free is now .1 again
    #expect(try await a.allocate(project: "shop", branch: "feature/two") == "127.0.10.1")
}

@Test func ipReturnsNilWhenUnallocated() async throws {
    let a = IPAllocator(fileURL: tempFile())
    #expect(await a.ip(project: "shop", branch: "nope") == nil)
    _ = try await a.allocate(project: "shop", branch: "main")
    #expect(await a.ip(project: "shop", branch: "main") == "127.0.10.1")
}

@Test func persistsAcrossInstances() async throws {
    let url = tempFile()
    let a = IPAllocator(fileURL: url)
    _ = try await a.allocate(project: "shop", branch: "main")
    let b = IPAllocator(fileURL: url)  // fresh instance, same file
    #expect(await b.ip(project: "shop", branch: "main") == "127.0.10.1")
}

@Test func exhaustionThrows() async throws {
    let a = IPAllocator(fileURL: tempFile())
    for i in 1...254 { _ = try await a.allocate(project: "p", branch: "b\(i)") }
    await #expect(throws: LoopbackError.self) {
        _ = try await a.allocate(project: "p", branch: "overflow")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter IPAllocator`
Expected: FAIL — `cannot find 'IPAllocator' in scope` / `cannot find 'LoopbackError' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/SproutEngine/Port/IPAllocator.swift`:

```swift
import Foundation

public enum LoopbackError: Error, Equatable {
    case exhausted
    case notAllocated(branch: String)
    case persistFailed(String)
}

public struct LoopbackAllocation: Codable, Sendable, Equatable {
    public var project: String
    public var branch: String
    public var ip: String

    public init(project: String, branch: String, ip: String) {
        self.project = project; self.branch = branch; self.ip = ip
    }
}

/// Global, persisted, sequential allocator: hands out 127.0.10.N across all
/// projects/branches, reusing freed slots. Serializes its whole table on each
/// write. Backed by its own JSON file (the `FileSystem` protocol has no read).
public actor IPAllocator {
    private static let prefix = "127.0.10."
    private static let lower = 1
    private static let upper = 254

    private let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func allocate(project: String, branch: String) throws -> String {
        var table = readAll()
        if let existing = table.first(where: { $0.project == project && $0.branch == branch }) {
            return existing.ip
        }
        let used = Set(table.compactMap { Self.octet($0.ip) })
        guard let free = (Self.lower...Self.upper).first(where: { !used.contains($0) }) else {
            throw LoopbackError.exhausted
        }
        let ip = "\(Self.prefix)\(free)"
        table.append(LoopbackAllocation(project: project, branch: branch, ip: ip))
        try writeAll(table)
        return ip
    }

    public func release(project: String, branch: String) throws {
        var table = readAll()
        table.removeAll { $0.project == project && $0.branch == branch }
        try writeAll(table)
    }

    public func ip(project: String, branch: String) -> String? {
        readAll().first(where: { $0.project == project && $0.branch == branch })?.ip
    }

    private static func octet(_ ip: String) -> Int? {
        guard ip.hasPrefix(prefix) else { return nil }
        return Int(ip.dropFirst(prefix.count))
    }

    private func readAll() -> [LoopbackAllocation] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
            let data = try? Data(contentsOf: fileURL), !data.isEmpty
        else { return [] }
        return (try? JSONDecoder().decode([LoopbackAllocation].self, from: data)) ?? []
    }

    private func writeAll(_ table: [LoopbackAllocation]) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(table).write(to: fileURL, options: .atomic)
        } catch {
            throw LoopbackError.persistFailed(String(describing: error))
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter IPAllocator`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Port/IPAllocator.swift Tests/SproutEngineTests/IPAllocatorTests.swift
git commit -m "feat: IPAllocator for per-workspace loopback IPs"
```

---

### Task 2: `{{host}}` in TemplateContext + TemplateRenderer

Add a `host` field (default `"127.0.0.1"`) and a `{{host}}` substitution.

**Files:**
- Modify: `Sources/SproutEngine/Config/TemplateRenderer.swift`
- Test: `Tests/SproutEngineTests/TemplateRendererTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/SproutEngineTests/TemplateRendererTests.swift`:

```swift
@Test func renderResolvesHostWithDefaultLoopback() {
    let ctx = TemplateContext(
        project: "shop", branch: "main", port: 4000,
        dbName: "shop", worktree: "/wt")
    #expect(ctx.host == "127.0.0.1")
    #expect(TemplateRenderer().render("-b {{host}} -p {{port}}", ctx) == "-b 127.0.0.1 -p 4000")
}

@Test func renderUsesExplicitHost() {
    let ctx = TemplateContext(
        project: "shop", branch: "main", port: 3000,
        dbName: "shop", worktree: "/wt", ports: ["web": 3000], host: "127.0.10.7")
    #expect(TemplateRenderer().render("rails -b {{host}} -p {{port}}", ctx)
        == "rails -b 127.0.10.7 -p 3000")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter renderResolvesHostWithDefaultLoopback`
Expected: FAIL — `extra argument 'host' in call` / `value of type 'TemplateContext' has no member 'host'`.

- [ ] **Step 3: Write the implementation**

In `Sources/SproutEngine/Config/TemplateRenderer.swift`, add the stored property to `TemplateContext` (after `ports`, line 9):

```swift
    public var ports: [String: Int]
    public var host: String
```

Update the initializer (lines 11-17) to add `host` with a default:

```swift
    public init(
        project: String, branch: String, port: Int, dbName: String,
        worktree: String, ports: [String: Int] = [:], host: String = "127.0.0.1"
    ) {
        self.project = project; self.branch = branch; self.port = port
        self.dbName = dbName; self.worktree = worktree; self.ports = ports
        self.host = host
    }
```

In `TemplateRenderer.render`, add `{{host}}` to the `map` dictionary (after the `{{port}}` entry, line 46):

```swift
            "{{port}}": String(ctx.port),
            "{{host}}": ctx.host,
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TemplateRenderer`
Expected: PASS (all existing TemplateRenderer tests + the 2 new ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Config/TemplateRenderer.swift Tests/SproutEngineTests/TemplateRendererTests.swift
git commit -m "feat: {{host}} template variable on TemplateContext"
```

---

### Task 3: `bindIP` on WorkspaceRecord (with migration)

Add `bindIP`, defaulting to `127.0.0.1` for records decoded from older JSON.

**Files:**
- Modify: `Sources/SproutEngine/State/StateStore.swift`
- Test: `Tests/SproutEngineTests/JSONStateStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/SproutEngineTests/JSONStateStoreTests.swift`:

```swift
@Test func recordDecodesWithoutBindIPDefaultsToLoopback() throws {
    // JSON from before bindIP existed (no "bindIP" key).
    let json = """
        {"id":"\(UUID().uuidString)","branch":"main","base":"main",
        "worktreePath":"/wt/main","port":3000,"dbName":"shop_main",
        "status":"stopped","createdAt":"2026-06-06T00:00:00Z","processes":[]}
        """
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    let rec = try dec.decode(WorkspaceRecord.self, from: Data(json.utf8))
    #expect(rec.bindIP == "127.0.0.1")
}

@Test func recordRoundTripsBindIP() throws {
    let rec = WorkspaceRecord(
        id: UUID(), branch: "main", base: "main", worktreePath: "/wt/main",
        port: 3000, dbName: "shop_main", status: .stopped,
        createdAt: Date(timeIntervalSince1970: 0), bindIP: "127.0.10.5")
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    let back = try dec.decode(WorkspaceRecord.self, from: enc.encode(rec))
    #expect(back.bindIP == "127.0.10.5")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter recordDecodesWithoutBindIPDefaultsToLoopback`
Expected: FAIL — `extra argument 'bindIP' in call` (the second test) and missing member.

- [ ] **Step 3: Write the implementation**

In `Sources/SproutEngine/State/StateStore.swift`, add the stored property to `WorkspaceRecord` (after `port`, line 23):

```swift
    public var port: Int
    public var bindIP: String
```

Update the memberwise initializer (lines 29-37) to add `bindIP` with a default and assign it:

```swift
    public init(
        id: UUID, branch: String, base: String, worktreePath: String,
        port: Int, dbName: String, status: WorkspaceStatus,
        createdAt: Date, processes: [ProcessState] = [], bindIP: String = "127.0.0.1"
    ) {
        self.id = id; self.branch = branch; self.base = base
        self.worktreePath = worktreePath; self.port = port; self.dbName = dbName
        self.status = status; self.createdAt = createdAt; self.processes = processes
        self.bindIP = bindIP
    }
```

In the custom `init(from:)` (lines 39-50), decode `bindIP` with a fallback (after the `port` decode, line 45):

```swift
        port = try c.decode(Int.self, forKey: .port)
        bindIP = try c.decodeIfPresent(String.self, forKey: .bindIP) ?? "127.0.0.1"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter JSONStateStore`
Expected: PASS (existing store tests + 2 new ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/State/StateStore.swift Tests/SproutEngineTests/JSONStateStoreTests.swift
git commit -m "feat: bindIP on WorkspaceRecord with loopback-default migration"
```

---

### Task 4: Thread `bindIP` through WorkspaceManager.create

`create` gains a `bindIP: String = "127.0.0.1"` parameter, stores it on the record, threads it into every per-process render context and child env (`HOST` + `BIND_IP`). Default keeps current behavior unchanged.

**Files:**
- Modify: `Sources/SproutEngine/Workspace/WorkspaceManager.swift`
- Test: `Tests/SproutEngineTests/WorkspaceManagerTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/SproutEngineTests/WorkspaceManagerTests.swift`:

```swift
@Test func createThreadsBindIPIntoRecordAndProcessEnvAndCommand() async throws {
    var cfg = Fixtures.config()
    cfg.setup = []
    cfg.run = RunConfig(processes: [
        ProcessConfig(name: "web", command: "rails -b {{host}} -p {{port}}", port: 3000)
    ])
    let shell = FakeShellRunner()
    // handle matched on the rendered host substring proves {{host}} was rendered
    shell.handles = [("rails -b 127.0.10.9", { FakeProcessHandle(pid: 5, exitCode: 0, lines: []) })]
    let store = FakeStateStore()
    let fs = FakeFileSystem(); fs.existing = ["/repo/.env"]
    let mgr = makeManager(shell: shell, store: store, fs: fs)

    let rec = try await mgr.create(
        config: cfg, repo: repo, base: "main", branch: "feature/login",
        bindIP: "127.0.10.9"
    ) { _, _ in }

    #expect(rec.bindIP == "127.0.10.9")
    let launch = shell.calls.first { $0.command.contains("rails -b") }
    #expect(launch?.command == "rails -b 127.0.10.9 -p 3000")
    #expect(launch?.env["HOST"] == "127.0.10.9")
    #expect(launch?.env["BIND_IP"] == "127.0.10.9")
}

@Test func createDefaultsBindIPToLoopback() async throws {
    let shell = FakeShellRunner()
    shell.handles = [("npm run dev", { FakeProcessHandle(pid: 900, exitCode: 0, lines: []) })]
    let store = FakeStateStore()
    let fs = FakeFileSystem(); fs.existing = ["/repo/.env"]
    let mgr = makeManager(shell: shell, store: store, fs: fs)

    let rec = try await mgr.create(
        config: Fixtures.config(), repo: repo, base: "main", branch: "feature/login"
    ) { _, _ in }

    #expect(rec.bindIP == "127.0.0.1")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter createThreadsBindIPIntoRecordAndProcessEnvAndCommand`
Expected: FAIL — `extra argument 'bindIP' in call`.

- [ ] **Step 3: Write the implementation**

In `Sources/SproutEngine/Workspace/WorkspaceManager.swift`:

Add a `host` parameter to the private `context` helper (lines 56-63), defaulting to loopback so `teardown`/`rollback` callers are unaffected:

```swift
    private func context(
        config: Config, branch: String, port: Int, ports: [String: Int],
        dbName: String, worktree: String, host: String = "127.0.0.1"
    ) -> TemplateContext {
        TemplateContext(
            project: config.project.name, branch: branch,
            port: port, dbName: dbName, worktree: worktree, ports: ports, host: host)
    }
```

Add the `bindIP` parameter to `create` (lines 74-80):

```swift
    public func create(
        config: Config, repo: URL, base: String, branch: String,
        bindIP: String = "127.0.0.1",
        log: @escaping @Sendable (_ stream: String, LogLine) -> Void,
        onProcessExit: @escaping @Sendable (_ name: String, _ pid: Int32, _ code: Int32) -> Void = {
            _, _, _ in
        }
    ) async throws -> WorkspaceRecord {
```

Pass `host: bindIP` into the main create context (lines 105-107):

```swift
            let ctx = context(
                config: config, branch: branch, port: port, ports: plan,
                dbName: dbName, worktree: worktreePath, host: bindIP)
```

Set `bindIP` on the persisted record (lines 120-123):

```swift
            var record = WorkspaceRecord(
                id: UUID(), branch: branch, base: base, worktreePath: worktreePath,
                port: port, dbName: dbName, status: .creating,
                createdAt: Date(), bindIP: bindIP)
```

Add `HOST`/`BIND_IP` to the setup child env (line 126):

```swift
            let childEnv = ["PORT": String(port), "DATABASE_URL": dbURL,
                "HOST": bindIP, "BIND_IP": bindIP]
```

In the per-process launch loop (lines 131-144), thread `host` into the per-process context and env:

```swift
            for proc in config.run.processes {
                let ownPort = proc.port ?? port
                let pctx = context(
                    config: config, branch: branch, port: ownPort, ports: plan,
                    dbName: dbName, worktree: worktreePath, host: bindIP)
                let penv = ["PORT": String(ownPort), "DATABASE_URL": dbURL,
                    "HOST": bindIP, "BIND_IP": bindIP]
```

(Leave the rest of the loop body unchanged.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WorkspaceManager`
Expected: PASS (all existing WorkspaceManager tests + 2 new ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Workspace/WorkspaceManager.swift Tests/SproutEngineTests/WorkspaceManagerTests.swift
git commit -m "feat: thread bindIP/host through WorkspaceManager.create"
```

---

### Task 5: LoopbackProvisioner protocol + Noop impl + hostname helper

The seam the privileged helper will sit behind. Includes a no-op implementation (the default wired into the app until the XPC helper exists) and a pure helper computing per-process hostnames. Also adds a recording fake to test support for use by Task 6.

**Files:**
- Create: `Sources/SproutEngine/Loopback/LoopbackProvisioner.swift`
- Create: `Tests/SproutEngineTests/Support/FakeLoopbackProvisioner.swift`
- Test: `Tests/SproutEngineTests/LoopbackProvisionerTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SproutEngineTests/LoopbackProvisionerTests.swift`:

```swift
import Testing
import Foundation
@testable import SproutEngine

@Test func hostnamesCoversOnlyPortBindingProcesses() {
    let procs = [
        ProcessConfig(name: "web", command: "rails", port: 3000),
        ProcessConfig(name: "vite", command: "vite", port: 5173),
        ProcessConfig(name: "worker", command: "jobs"),   // no port
    ]
    let hosts = loopbackHostnames(project: "My Shop", processes: procs)
    #expect(hosts == ["web.my_shop.localhost", "vite.my_shop.localhost"])
}

@Test func hostnamesEmptyWhenNoBinders() {
    let procs = [ProcessConfig(name: "worker", command: "jobs")]
    #expect(loopbackHostnames(project: "shop", processes: procs).isEmpty)
}

@Test func noopProvisionerDoesNothingAndDoesNotThrow() async throws {
    let p = NoopLoopbackProvisioner()
    try await p.setActive(ip: "127.0.10.1", hosts: ["web.shop.localhost"], active: true)
    try await p.setActive(ip: "127.0.10.1", hosts: ["web.shop.localhost"], active: false)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LoopbackProvisioner`
Expected: FAIL — `cannot find 'loopbackHostnames' in scope` / `cannot find 'NoopLoopbackProvisioner' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/SproutEngine/Loopback/LoopbackProvisioner.swift`:

```swift
import Foundation

public enum ProvisionError: Error, Equatable {
    case helperUnavailable
    case helperRejected(String)
    case ifconfigFailed(String)
    case hostsWriteFailed(String)
}

/// Installs or removes a loopback alias plus its `/etc/hosts` entries for one
/// workspace IP. The real implementation talks to a privileged helper over XPC
/// (follow-up plan); engine and tests depend only on this protocol.
public protocol LoopbackProvisioner: Sendable {
    func setActive(ip: String, hosts: [String], active: Bool) async throws
}

/// Default no-op. Wired into the app until the XPC helper exists, so behavior is
/// unchanged (no aliases created; workspaces keep binding 127.0.0.1).
public struct NoopLoopbackProvisioner: LoopbackProvisioner {
    public init() {}
    public func setActive(ip: String, hosts: [String], active: Bool) async throws {}
}

/// Per-process hostnames for a workspace: `<process>.<project>.localhost` for
/// every port-binding process. Used to populate the `/etc/hosts` managed block.
public func loopbackHostnames(project: String, processes: [ProcessConfig]) -> [String] {
    let projectSlug = TemplateContext.slugify(project)
    return processes
        .filter { $0.port != nil }
        .map { "\(TemplateContext.slugify($0.name)).\(projectSlug).localhost" }
}
```

Create `Tests/SproutEngineTests/Support/FakeLoopbackProvisioner.swift`:

```swift
import Foundation
@testable import SproutEngine

/// Records every setActive call. `failNext` makes the next call throw, to test
/// provision-failure handling.
final class FakeLoopbackProvisioner: LoopbackProvisioner, @unchecked Sendable {
    struct Call: Equatable { let ip: String; let hosts: [String]; let active: Bool }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _failNext = false

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }

    func setFailNext(_ value: Bool) { lock.lock(); _failNext = value; lock.unlock() }

    func setActive(ip: String, hosts: [String], active: Bool) async throws {
        lock.lock()
        let shouldFail = _failNext
        _failNext = false
        _calls.append(Call(ip: ip, hosts: hosts, active: active))
        lock.unlock()
        if shouldFail { throw ProvisionError.helperUnavailable }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LoopbackProvisioner`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Loopback/LoopbackProvisioner.swift Tests/SproutEngineTests/LoopbackProvisionerTests.swift Tests/SproutEngineTests/Support/FakeLoopbackProvisioner.swift
git commit -m "feat: LoopbackProvisioner seam + noop impl + hostname helper"
```

---

### Task 6: LoopbackCoordinator (reference-counted provisioning)

Owns the per-branch running-process count and calls the provisioner exactly once on the first start (`0 -> 1`) and once on the last stop (`1 -> 0`). This is the unit-testable core of the "provision on start, release when all stop" rule; `ProjectStore` will call it (follow-up plan). Idempotency on the helper side means a duplicate `activate` is harmless, but the coordinator still gates calls to avoid churn.

**Files:**
- Create: `Sources/SproutEngine/Loopback/LoopbackCoordinator.swift`
- Test: `Tests/SproutEngineTests/LoopbackCoordinatorTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SproutEngineTests/LoopbackCoordinatorTests.swift`:

```swift
import Testing
import Foundation
@testable import SproutEngine

private let hosts = ["web.shop.localhost", "vite.shop.localhost"]

@Test func firstActivateProvisionsOnce() async throws {
    let fake = FakeLoopbackProvisioner()
    let c = LoopbackCoordinator(provisioner: fake)
    try await c.activate(branch: "main", ip: "127.0.10.1", hosts: hosts)
    try await c.activate(branch: "main", ip: "127.0.10.1", hosts: hosts)  // 2nd process
    #expect(fake.calls == [.init(ip: "127.0.10.1", hosts: hosts, active: true)])
}

@Test func lastDeactivateReleasesOnce() async throws {
    let fake = FakeLoopbackProvisioner()
    let c = LoopbackCoordinator(provisioner: fake)
    try await c.activate(branch: "main", ip: "127.0.10.1", hosts: hosts)  // count 1
    try await c.activate(branch: "main", ip: "127.0.10.1", hosts: hosts)  // count 2
    await c.deactivate(branch: "main", ip: "127.0.10.1", hosts: hosts)    // count 1, no release
    await c.deactivate(branch: "main", ip: "127.0.10.1", hosts: hosts)    // count 0, release
    #expect(fake.calls == [
        .init(ip: "127.0.10.1", hosts: hosts, active: true),
        .init(ip: "127.0.10.1", hosts: hosts, active: false),
    ])
}

@Test func deactivateBelowZeroDoesNotDoubleRelease() async throws {
    let fake = FakeLoopbackProvisioner()
    let c = LoopbackCoordinator(provisioner: fake)
    try await c.activate(branch: "main", ip: "127.0.10.1", hosts: hosts)
    await c.deactivate(branch: "main", ip: "127.0.10.1", hosts: hosts)  // -> 0, release
    await c.deactivate(branch: "main", ip: "127.0.10.1", hosts: hosts)  // already 0, no-op
    let releases = fake.calls.filter { !$0.active }
    #expect(releases.count == 1)
}

@Test func failedActivateDoesNotIncrementCount() async throws {
    let fake = FakeLoopbackProvisioner()
    fake.setFailNext(true)
    let c = LoopbackCoordinator(provisioner: fake)
    await #expect(throws: ProvisionError.self) {
        try await c.activate(branch: "main", ip: "127.0.10.1", hosts: hosts)
    }
    // A subsequent successful activate is treated as the first (0 -> 1) again.
    try await c.activate(branch: "main", ip: "127.0.10.1", hosts: hosts)
    #expect(fake.calls.filter { $0.active }.count == 2)  // failed attempt + real first
    #expect(fake.calls.last == .init(ip: "127.0.10.1", hosts: hosts, active: true))
}

@Test func branchesAreIndependent() async throws {
    let fake = FakeLoopbackProvisioner()
    let c = LoopbackCoordinator(provisioner: fake)
    try await c.activate(branch: "a", ip: "127.0.10.1", hosts: hosts)
    try await c.activate(branch: "b", ip: "127.0.10.2", hosts: hosts)
    #expect(fake.calls.filter { $0.active }.count == 2)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LoopbackCoordinator`
Expected: FAIL — `cannot find 'LoopbackCoordinator' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/SproutEngine/Loopback/LoopbackCoordinator.swift`:

```swift
import Foundation

/// Reference-counts running processes per branch and drives the provisioner on
/// the transitions that matter: install the alias + hosts on the first start
/// (0 -> 1), remove them on the last stop (1 -> 0).
///
/// `activate` provisions BEFORE incrementing, so a failed provision leaves the
/// count untouched and the caller can abort the start. `deactivate` never
/// throws — a failed release is logged-and-forgotten (stale state is reaped by
/// the launch sweep in the follow-up plan).
public actor LoopbackCoordinator {
    private let provisioner: LoopbackProvisioner
    private var counts: [String: Int] = [:]

    public init(provisioner: LoopbackProvisioner) {
        self.provisioner = provisioner
    }

    public func activate(branch: String, ip: String, hosts: [String]) async throws {
        let current = counts[branch] ?? 0
        if current == 0 {
            try await provisioner.setActive(ip: ip, hosts: hosts, active: true)
        }
        counts[branch] = current + 1
    }

    public func deactivate(branch: String, ip: String, hosts: [String]) async {
        let current = counts[branch] ?? 0
        guard current > 0 else { return }
        let next = current - 1
        counts[branch] = next
        if next == 0 {
            counts[branch] = nil
            try? await provisioner.setActive(ip: ip, hosts: hosts, active: false)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LoopbackCoordinator`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Loopback/LoopbackCoordinator.swift Tests/SproutEngineTests/LoopbackCoordinatorTests.swift
git commit -m "feat: LoopbackCoordinator refcounts provisioning per branch"
```

---

### Task 7: Thread `host` through ProjectStore render contexts

Make the app read `rec.bindIP` when building render contexts and child envs, so once the follow-up plan hands out real `127.0.10.x` addresses the running processes bind them. Until then every record has `bindIP == "127.0.0.1"`, so this is non-breaking. No allocator/coordinator wiring yet (that is the follow-up plan, where the real provisioner exists). This task has no unit test — `ProjectStore` spawns real processes and is verified by build; the behavior change is covered by `WorkspaceManagerTests` (Task 4) which exercises the same threading in the engine.

**Files:**
- Modify: `Sources/SproutApp/Model/ProjectStore.swift:116-129`

- [ ] **Step 1: Make the edit**

In `Sources/SproutApp/Model/ProjectStore.swift`, update `context(_:process:)` (lines 116-122) to pass `host: rec.bindIP`:

```swift
    private func context(_ rec: WorkspaceRecord, process name: String? = nil) -> TemplateContext {
        let plan = portPlan(config.run.processes)
        let own = name.flatMap { plan[$0] } ?? rec.port
        return TemplateContext(
            project: config.project.name, branch: rec.branch,
            port: own, dbName: rec.dbName, worktree: rec.worktreePath, ports: plan,
            host: rec.bindIP)
    }
```

Update `childEnv(_:process:)` (lines 124-129) to add `HOST`/`BIND_IP`:

```swift
    private func childEnv(_ rec: WorkspaceRecord, process name: String? = nil) -> [String: String] {
        let ctx = context(rec, process: name)
        let url = DatabaseService(shell: shell, renderer: renderer)
            .databaseURL(config.database, ctx: ctx)
        return ["PORT": String(ctx.port), "DATABASE_URL": url,
            "HOST": rec.bindIP, "BIND_IP": rec.bindIP]
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!` with no warnings.

- [ ] **Step 3: Run the full suite**

Run: `swift test`
Expected: all tests PASS (no regressions).

- [ ] **Step 4: Commit**

```bash
git add Sources/SproutApp/Model/ProjectStore.swift
git commit -m "feat: ProjectStore renders host/bindIP into process contexts"
```

---

### Task 8: Update sample `.sprout.toml` + document the `{{host}}` binding contract

Make the bind-to-`{{host}}` contract discoverable: every port-binding process must bind `{{host}}`, never `0.0.0.0`, or the per-IP isolation breaks. Update the repo's own `.sprout.toml` sample and the CLAUDE.md gotchas.

**Files:**
- Modify: `.sprout.toml`
- Modify: `CLAUDE.md` (Gotchas section)

- [ ] **Step 1: Read the current sample**

Run: `cat .sprout.toml`
Note the existing `[[run.process]]` entries and their `command` strings.

- [ ] **Step 2: Update each port-binding process command to bind `{{host}}`**

For every `[[run.process]]` that has `port = <n>`, ensure its `command` binds the host. Examples (adapt to the actual commands present):

```toml
[[run.process]]
name = "web"
command = "bin/rails server -b {{host}} -p {{port}}"
port = 3000

[[run.process]]
name = "vite"
command = "bin/vite dev --host {{host}} --port {{port}} --strictPort"
port = 5173
```

Leave non-port processes (no `port` key) unchanged.

- [ ] **Step 3: Add the contract to CLAUDE.md gotchas**

In `CLAUDE.md`, under "## Gotchas (learned the hard way)", add a bullet:

```markdown
- **Per-workspace loopback IPs require binding `{{host}}`, not `0.0.0.0`.** Each
  workspace gets its own `127.0.10.N` (so branches reuse the same internal ports
  concurrently). A process that binds `0.0.0.0` grabs the port on *every* loopback
  IP, re-introducing collisions. Every port-binding `[[run.process]]` command must
  pass `{{host}}` (e.g. `rails server -b {{host}}`, `vite --host {{host}}
  --strictPort`). `{{host}}` defaults to `127.0.0.1` when the loopback feature is
  inactive, so the same config works in both modes.
```

- [ ] **Step 4: Verify the sample still parses**

Run: `swift build && swift run sprout --help`
Expected: builds and the CLI runs (no TOML parse error on load paths). If the repo has a config-validation command, run that instead.

- [ ] **Step 5: Commit**

```bash
git add .sprout.toml CLAUDE.md
git commit -m "docs: document {{host}} binding contract for loopback IPs"
```

---

## Self-Review

**Spec coverage (Plan 1 scope = engine seam):**
- IPAllocator (global, sequential, reuse, persist, exhaustion) — Task 1. ✓
- `{{host}}` template var — Task 2. ✓
- `bindIP` on record + migration — Task 3. ✓
- `bindIP`/`host` threaded through create (record, env, command) — Task 4. ✓
- `LoopbackProvisioner` protocol + `ProvisionError` + hostname helper — Task 5. ✓
- Refcount "provision on first / release on last" — Task 6 (`LoopbackCoordinator`). ✓
- App reads `bindIP` for render/env — Task 7. ✓
- `{{host}}` binding contract documented — Task 8. ✓

**Deferred to follow-up plan (`2026-06-06-loopback-ips-helper-and-bundling.md`), intentionally out of scope here:** SMAppService daemon, XPC protocol + `HelperProtocol` (`setActive`/`ping`/`listManaged`), helper-side validation (cert pin, IP regex, hostname regex), `/etc/hosts` managed-block rewrite, `ifconfig` invocation, `XPCProvisioner`, `.app` bundling + self-signed signing (`Makefile`, `scripts/bundle.sh`, `make certs`), `ProjectStore` allocation/coordinator wiring at create/start/stop/teardown, app-launch + helper-boot sweeps, manual verification checklist. These depend on a signed bundle and cannot run under `swift test`, so they form their own plan.

**Placeholder scan:** No TBD/TODO; every code step shows complete code; commands have expected output. ✓

**Type consistency:**
- `TemplateContext(... ports:, host:)` initializer signature matches its use in Task 2 tests, Task 4 (`WorkspaceManager.context`), and Task 7 (`ProjectStore.context`). ✓
- `WorkspaceRecord(... bindIP:)` initializer matches Task 3 tests and Task 4 create. ✓
- `LoopbackProvisioner.setActive(ip:hosts:active:)` signature identical across the protocol (Task 5), `NoopLoopbackProvisioner`, `FakeLoopbackProvisioner` (Task 5), and `LoopbackCoordinator` (Task 6). ✓
- `loopbackHostnames(project:processes:)` defined in Task 5, used in Task 6 tests' `hosts` fixtures (literal there) — no signature mismatch. ✓
- `LoopbackCoordinator.activate(branch:ip:hosts:)` / `deactivate(branch:ip:hosts:)` consistent between impl and tests. ✓
- `IPAllocator.allocate/release/ip` async actor methods match test `await` usage. ✓
