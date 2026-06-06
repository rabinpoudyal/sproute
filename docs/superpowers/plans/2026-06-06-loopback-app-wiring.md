# Loopback App Wiring (Plan 2b-1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the existing engine loopback layer (`IPAllocator` + `LoopbackCoordinator`) into the macOS app's `ProjectStore` so a workspace allocates a per-branch loopback IP at create, refcount-provisions it on the first process start, releases it on the last process exit, and frees the IP at teardown.

**Architecture:** Inject `IPAllocator` + `LoopbackCoordinator` + a `loopbackEnabled` flag into `ProjectStore` (defaults preserve today's behavior: feature OFF, `NoopLoopbackProvisioner`, `bindIP` stays `127.0.0.1`). All loopback logic lands behind small, internal, unit-testable seam methods (`allocateBindIP`, `releaseBindIP`, `activateLoopback`, `deactivateLoopback`). The five call sites (`create`, `startProcess`, `handleProcessExit`, `teardown`) call only those seam methods. The privileged provisioner, signing, and reapers are deferred to Plans 2b-2 / 2b-3 — this plan changes no production runtime behavior because the feature ships disabled.

**Tech Stack:** Swift 6 strict concurrency, Swift Testing (`import Testing`), `@MainActor` view-model, `actor` engine seams. Tests inject a `RecordingProvisioner` fake; no real processes are spawned.

---

## Design Notes (read before starting)

**Why the feature ships OFF (`loopbackEnabled = false` default):** With the default `NoopLoopbackProvisioner`, no `lo0` alias is ever created. If we allocated `127.0.10.N` and set it as `bindIP`, dev servers would try to bind an unconfigured IP and fail. So when disabled: `allocateBindIP` returns `"127.0.0.1"`, and `activate/deactivateLoopback` are no-ops. The wiring is fully exercised by unit tests with the flag forced on; production stays on `127.0.0.1` until Plan 2b-2 lands the real privileged provisioner and flips the flag.

**Refcount ownership — deactivate happens in exactly ONE place.** Every successful process start calls `activateLoopback` (+1). Every genuine process end calls `deactivateLoopback` (−1) via `handleProcessExit`, which is guarded by a pid match (a late exit for an already-replaced/stopped pid is ignored). `stopProcess` does NOT deactivate — killing the process triggers its exit callback, which drives the refcount down. The one exception: if `sup.start` *throws* (process never came up, so no exit callback will ever fire), `startProcess` calls `deactivateLoopback` itself to undo the `+1`.

**Teardown frees the IP, not the alias.** `teardown` calls `releaseBindIP` to return the `127.0.10.N` slot to the allocator. Alias/`/etc/hosts` cleanup happens as the killed processes fire their exit callbacks (refcount → 0), with the launch-sweep reaper (Plan 2b-2) catching any residue. `teardown` does not call the coordinator directly.

**Existing signatures (verbatim, do not change):**
- `WorkspaceManager.create(config:repo:base:branch:bindIP:String = "127.0.0.1",log:onProcessExit:)`
- `IPAllocator.init(fileURL:)`, `actor` methods `allocate(project:branch:) throws -> String`, `release(project:branch:) throws`, `ip(project:branch:) -> String?`
- `LoopbackCoordinator.init(provisioner:)`, `activate(branch:ip:hosts:) async throws`, `deactivate(branch:ip:hosts:) async`
- `public func loopbackHostnames(project:processes:) -> [String]`
- `WorkspaceRecord.init(id:branch:base:worktreePath:port:dbName:status:createdAt:processes:bindIP:)`
- `protocol LoopbackProvisioner: Sendable { func setActive(ip:hosts:active:) async throws }`, `NoopLoopbackProvisioner`, `ProvisionError.helperUnavailable`

## File Structure

- **Modify** `Sources/SproutApp/Model/SproutPaths.swift` — add `loopbackFile`.
- **Modify** `Sources/SproutApp/Model/ProjectStore.swift` — inject deps; add seam methods; wire 4 call sites.
- **Create** `Tests/SproutAppTests/ProjectStoreLoopbackTests.swift` — `RecordingProvisioner` fake + seam tests.

---

### Task 1: `SproutPaths.loopbackFile`

**Files:**
- Modify: `Sources/SproutApp/Model/SproutPaths.swift`
- Test: `Tests/SproutAppTests/ProjectStoreLoopbackTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/SproutAppTests/ProjectStoreLoopbackTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProjectStoreLoopbackTests`
Expected: FAIL — `loopbackFile` is not a member of `SproutPaths`.

- [ ] **Step 3: Add the property**

In `Sources/SproutApp/Model/SproutPaths.swift`, add after `registryFile`:

```swift
    /// Global loopback IP allocation table (127.0.10.N per project/branch).
    static var loopbackFile: URL {
        root.appendingPathComponent("loopback.json")
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ProjectStoreLoopbackTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutApp/Model/SproutPaths.swift Tests/SproutAppTests/ProjectStoreLoopbackTests.swift
git commit -m "feat: add SproutPaths.loopbackFile for IP allocation table"
```

---

### Task 2: Inject deps + `activate`/`deactivateLoopback` seam (refcount)

**Files:**
- Modify: `Sources/SproutApp/Model/ProjectStore.swift:38-78` (props + init + makeManager region)
- Test: `Tests/SproutAppTests/ProjectStoreLoopbackTests.swift`

- [ ] **Step 1: Add the `RecordingProvisioner` fake + test helpers**

Append to `Tests/SproutAppTests/ProjectStoreLoopbackTests.swift` (inside the file, after the `@Suite` struct's closing brace — these are file-scope helpers):

```swift
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
```

- [ ] **Step 2: Write the failing refcount tests**

Add inside the `@Suite struct ProjectStoreLoopbackTests { ... }` body:

```swift
    @Test @MainActor func activateProvisionsOncePerBranchRefcount() async throws {
        let prov = RecordingProvisioner()
        let store = makeLoopbackStore(
            prov: prov, enabled: true,
            processes: [ProcessConfig(name: "web", command: "true", port: 3000)])
        let rec = makeLoopbackRecord(branch: "feature/x", bindIP: "127.0.10.7")

        try await store.activateLoopback(rec)
        try await store.activateLoopback(rec)
        #expect(prov.calls == [
            .init(ip: "127.0.10.7", hosts: ["web.my-shop.localhost"], active: true)
        ])

        await store.deactivateLoopback(rec)
        await store.deactivateLoopback(rec)
        #expect(prov.calls == [
            .init(ip: "127.0.10.7", hosts: ["web.my-shop.localhost"], active: true),
            .init(ip: "127.0.10.7", hosts: ["web.my-shop.localhost"], active: false),
        ])
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
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter ProjectStoreLoopbackTests`
Expected: FAIL — `ProjectStore` has no `loopbackEnabled:` init param and no `activateLoopback`/`deactivateLoopback`.

- [ ] **Step 4: Inject deps and add the seam**

In `Sources/SproutApp/Model/ProjectStore.swift`, add stored properties after `private let manager: WorkspaceManager` (line 41):

```swift
    private let loopbackEnabled: Bool
    private let allocator: IPAllocator
    private let loopback: LoopbackCoordinator
```

Replace the initializer (lines 52-61) with:

```swift
    init(
        rootURL: URL, config: Config,
        loopbackEnabled: Bool = false,
        allocator: IPAllocator? = nil,
        loopback: LoopbackCoordinator? = nil
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.id = self.rootURL.path
        self.config = config
        let store = JSONStateStore(fileURL: SproutPaths.stateFile(projectName: config.project.name))
        self.store = store
        self.manager = ProjectStore.makeManager(
            config: config, store: store,
            shell: shell, renderer: renderer)
        self.loopbackEnabled = loopbackEnabled
        self.allocator = allocator ?? IPAllocator(fileURL: SproutPaths.loopbackFile)
        self.loopback = loopback ?? LoopbackCoordinator(provisioner: NoopLoopbackProvisioner())
    }
```

Add the seam methods in the `// MARK: - Lifecycle actions` region, right before `func create` (line 137):

```swift
    /// Hostnames provisioned for this project's port-binding processes.
    private func loopbackHosts() -> [String] {
        loopbackHostnames(project: config.project.name, processes: config.run.processes)
    }

    /// Refcounted provision of the branch's loopback alias + hosts (no-op when the
    /// feature is disabled). Throws if provisioning fails so the caller can abort the
    /// start before spawning a process that would bind an unconfigured IP.
    func activateLoopback(_ rec: WorkspaceRecord) async throws {
        guard loopbackEnabled else { return }
        try await loopback.activate(branch: rec.branch, ip: rec.bindIP, hosts: loopbackHosts())
    }

    /// Refcounted release of the branch's loopback alias + hosts (no-op when the
    /// feature is disabled). Never throws — stale state is reaped by the launch sweep.
    func deactivateLoopback(_ rec: WorkspaceRecord) async {
        guard loopbackEnabled else { return }
        await loopback.deactivate(branch: rec.branch, ip: rec.bindIP, hosts: loopbackHosts())
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter ProjectStoreLoopbackTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/SproutApp/Model/ProjectStore.swift Tests/SproutAppTests/ProjectStoreLoopbackTests.swift
git commit -m "feat: inject loopback deps + refcounted activate/deactivate seam into ProjectStore"
```

---

### Task 3: `activateLoopback` propagates provision failure

**Files:**
- Test: `Tests/SproutAppTests/ProjectStoreLoopbackTests.swift`
- (No source change — verifies the throw path already wired in Task 2.)

- [ ] **Step 1: Write the failing test**

Add inside the `@Suite struct ProjectStoreLoopbackTests` body:

```swift
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
```

- [ ] **Step 2: Run test to verify it passes**

Run: `swift test --filter ProjectStoreLoopbackTests`
Expected: PASS — `LoopbackCoordinator.activate` provisions before incrementing, so a failed activate does not bump the count; the retry provisions again (2 `active: true` calls).

If it FAILS, the coordinator's count was bumped on failure — that is a regression in `LoopbackCoordinator`, not this plan; stop and investigate.

- [ ] **Step 3: Commit**

```bash
git add Tests/SproutAppTests/ProjectStoreLoopbackTests.swift
git commit -m "test: activateLoopback propagates provision failure without leaking refcount"
```

---

### Task 4: `allocateBindIP` + wire `create`

**Files:**
- Modify: `Sources/SproutApp/Model/ProjectStore.swift:137-157` (`create`)
- Test: `Tests/SproutAppTests/ProjectStoreLoopbackTests.swift`

- [ ] **Step 1: Write the failing tests**

Add inside the `@Suite struct ProjectStoreLoopbackTests` body:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProjectStoreLoopbackTests`
Expected: FAIL — `allocateBindIP` does not exist.

- [ ] **Step 3: Add `allocateBindIP` and wire `create`**

In `Sources/SproutApp/Model/ProjectStore.swift`, add right after `deactivateLoopback` (from Task 2):

```swift
    /// The bind IP for a new workspace: an allocated 127.0.10.N when the loopback
    /// feature is on, otherwise 127.0.0.1 (so disabled mode keeps today's behavior).
    func allocateBindIP(branch: String) async throws -> String {
        guard loopbackEnabled else { return "127.0.0.1" }
        return try await allocator.allocate(project: config.project.name, branch: branch)
    }
```

Then in `create` (lines 149-156), thread the bind IP into `manager.create`:

```swift
        do {
            let bindIP = try await allocateBindIP(branch: branch)
            _ = try await manager.create(
                config: config, repo: rootURL,
                base: base, branch: branch, bindIP: bindIP, log: route, onProcessExit: onExit)
            refresh()
        } catch {
            lastError = AppError(error)
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProjectStoreLoopbackTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutApp/Model/ProjectStore.swift Tests/SproutAppTests/ProjectStoreLoopbackTests.swift
git commit -m "feat: allocate per-branch loopback IP at workspace create"
```

---

### Task 5: `releaseBindIP` + wire `teardown`

**Files:**
- Modify: `Sources/SproutApp/Model/ProjectStore.swift:361-383` (`teardown`)
- Test: `Tests/SproutAppTests/ProjectStoreLoopbackTests.swift`

- [ ] **Step 1: Write the failing test**

Add inside the `@Suite struct ProjectStoreLoopbackTests` body:

```swift
    @Test @MainActor func releaseBindIPFreesTheAllocation() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("sprout-rel-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = makeLoopbackStore(
            prov: RecordingProvisioner(), enabled: true, processes: [], allocFile: file)

        // Drive the allocator directly so we control the slot, then release via the seam.
        let alloc = IPAllocator(fileURL: file)
        _ = try await alloc.allocate(project: "My Shop", branch: "feature/z")
        #expect(await alloc.ip(project: "My Shop", branch: "feature/z") == "127.0.10.1")

        await store.releaseBindIP(branch: "feature/z")
        #expect(await alloc.ip(project: "My Shop", branch: "feature/z") == nil)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProjectStoreLoopbackTests`
Expected: FAIL — `releaseBindIP` does not exist.

- [ ] **Step 3: Add `releaseBindIP` and wire `teardown`**

In `Sources/SproutApp/Model/ProjectStore.swift`, add right after `allocateBindIP` (from Task 4):

```swift
    /// Return the branch's loopback IP slot to the allocator (no-op when disabled).
    /// Idempotent: releasing an unallocated branch is harmless.
    func releaseBindIP(branch: String) async {
        guard loopbackEnabled else { return }
        try? await allocator.release(project: config.project.name, branch: branch)
    }
```

Then in `teardown`, call it after `manager.teardown` succeeds. Replace the body between `try await manager.teardown(...)` and `refresh()` (lines 374-379) with:

```swift
            try await manager.teardown(
                id: item.record.id, config: config,
                repo: rootURL, push: push, force: force)
            await releaseBindIP(branch: item.record.branch)
            supervisors = supervisors.filter { $0.key.branch != item.record.branch }
            buffers = buffers.filter { $0.key.branch != item.record.branch }
            refresh()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ProjectStoreLoopbackTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutApp/Model/ProjectStore.swift Tests/SproutAppTests/ProjectStoreLoopbackTests.swift
git commit -m "feat: release loopback IP allocation at workspace teardown"
```

---

### Task 6: Wire `startProcess` (activate + abort + undo) and `handleProcessExit` (deactivate)

**Files:**
- Modify: `Sources/SproutApp/Model/ProjectStore.swift:162-172` (`handleProcessExit`), `:179-207` (`startProcess`)
- Test: `Tests/SproutAppTests/ProjectStoreLoopbackTests.swift`

- [ ] **Step 1: Write the failing test**

Add inside the `@Suite struct ProjectStoreLoopbackTests` body:

```swift
    @Test @MainActor func startAbortsWhenProvisionFails() async {
        let prov = RecordingProvisioner()
        prov.setFailNext(true)
        let store = makeLoopbackStore(
            prov: prov, enabled: true,
            processes: [ProcessConfig(name: "web", command: "true", port: 3000)])
        let rec = makeLoopbackRecord(branch: "feature/x", bindIP: "127.0.10.7")
        let item = WorkspaceItem(record: rec, orphaned: false)

        await store.startProcess(item, name: "web")

        // Provision was attempted once and failed; the process was never spawned.
        #expect(store.lastError != nil)
        #expect(prov.calls == [
            .init(ip: "127.0.10.7", hosts: ["web.my-shop.localhost"], active: true)
        ])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProjectStoreLoopbackTests`
Expected: FAIL — `startProcess` does not yet call `activateLoopback`, so `prov.calls` is empty and (worse) a real `true` process may be spawned.

- [ ] **Step 3: Wire `startProcess`**

In `Sources/SproutApp/Model/ProjectStore.swift`, replace `startProcess` (lines 179-207) with:

```swift
    func startProcess(_ item: WorkspaceItem, name: String) async {
        guard let command = command(for: name) else { return }
        var rec = item.record
        let key = ProcessKey(branch: rec.branch, name: name)
        // terminate any existing pid for this process
        if let existing = rec.processes.first(where: { $0.name == name })?.pid {
            await PosixProcessTerminator().terminate(pid: existing, graceSeconds: 5)
        }
        // Provision the loopback alias on the first start (refcounted). Abort before
        // spawning if it fails — a process bound to an unconfigured IP would just error.
        do {
            try await activateLoopback(rec)
        } catch {
            lastError = AppError(error)
            return
        }
        let sup = ServerSupervisor(shell: shell, renderer: renderer)
        let branch = rec.branch
        let onExit: @Sendable (Int32, Int32) -> Void = { [weak self] pid, code in
            Task { @MainActor in
                self?.handleProcessExit(branch: branch, name: name, pid: pid, code: code)
            }
        }
        do {
            let pid = try await sup.start(
                command: command, ctx: context(rec, process: name),
                cwd: URL(fileURLWithPath: rec.worktreePath),
                env: childEnv(rec, process: name), onLog: onLog(branch: rec.branch, process: name),
                onExit: onExit)
            supervisors[key] = sup
            upsertProcess(&rec, ProcessState(name: name, pid: pid, status: .running))
            try store.upsert(rec)
            refresh()
        } catch {
            // Spawn failed, so no exit callback will fire to release the refcount —
            // undo the activate ourselves.
            await deactivateLoopback(rec)
            lastError = AppError(error)
        }
    }
```

- [ ] **Step 4: Wire `handleProcessExit`**

Replace `handleProcessExit` (lines 162-172) with:

```swift
    private func handleProcessExit(branch: String, name: String, pid: Int32, code: Int32) {
        guard var rec = try? store.load().first(where: { $0.branch == branch }),
            let i = rec.processes.firstIndex(where: { $0.name == name }),
            rec.processes[i].pid == pid
        else { return }
        rec.processes[i].status = (code == 0) ? .stopped : .crashed
        rec.processes[i].pid = nil
        rec.status = aggregateStatus(rec.processes)
        try? store.upsert(rec)
        // A genuine exit (pid matched) releases one refcount; the alias is torn down
        // on the last process out. Snapshot the record for the async release.
        let snapshot = rec
        Task { await self.deactivateLoopback(snapshot) }
        refresh()
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter ProjectStoreLoopbackTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SproutApp/Model/ProjectStore.swift Tests/SproutAppTests/ProjectStoreLoopbackTests.swift
git commit -m "feat: provision loopback on first process start, release on last exit"
```

---

### Task 7: Full suite green + default-off behavior unchanged

**Files:** none (verification only).

- [ ] **Step 1: Lint**

Run: `swift format lint -r Sources Tests`
Expected: no output (clean). Do NOT run `swift format format -i`.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds all three products, warning-free.

- [ ] **Step 3: Full test suite**

Run: `swift test`
Expected: full suite passes (existing tests + the new `ProjectStoreLoopbackTests`). Because `loopbackEnabled` defaults to `false`, no existing behavior changes — `create` still passes `127.0.0.1`, `start`/`stop`/`teardown` make no provisioner calls.

- [ ] **Step 4: Gated integration suite (sanity)**

Run: `SPROUT_INTEGRATION=1 swift test`
Expected: passes (no new integration tests added; confirms nothing regressed).

- [ ] **Step 5: Confirm no production wiring is live**

Grep that the app constructs `ProjectStore` without enabling the flag (so the feature stays OFF until 2b-2):

Run: `grep -rn "ProjectStore(" Sources/SproutApp`
Expected: call sites use the `rootURL:config:` form only (no `loopbackEnabled: true`). If any production call site passes `loopbackEnabled: true`, that is out of scope for 2b-1 — leave the feature disabled.

---

## Self-Review

- **Spec coverage:** `loopbackFile` (T1), dep injection + refcount seam (T2), failure propagation (T3), allocate@create (T4), release@teardown (T5), provision@start / release@exit + abort (T6), green build/behavior-unchanged (T7). All wiring from the 2b-1 scope covered.
- **Type consistency:** Seam method names (`allocateBindIP`, `releaseBindIP`, `activateLoopback`, `deactivateLoopback`) used identically in source and tests. Project name `"My Shop"` → `hostnameSlug` → `my-shop`; process `web` → host `web.my-shop.localhost` (matches `loopbackHostnames` + `isValidLoopbackHostname`). `WorkspaceRecord`/`Config`/`ProcessConfig` initializers match verbatim signatures read from source.
- **No placeholders:** every code step is complete and copy-pasteable.
- **Scope:** privileged provisioner, XPC, signing, reapers all deferred (2b-2/2b-3). Feature ships disabled; production behavior unchanged.
```