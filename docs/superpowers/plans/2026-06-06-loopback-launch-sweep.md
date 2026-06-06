# Loopback App-Launch Sweep (Plan 2b-4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On app launch, clear stale `lo0` aliases + `/etc/hosts` SPROUT entries left by a prior crash, by asking the helper what it still manages and tearing down anything no longer backed by a live workspace.

**Architecture:** Add a `listManaged()` read to the `LoopbackProvisioner` seam. `LoopbackCoordinator` gains a stateless `sweep(live:)` that diffs the helper's managed IPs against the live set (via the existing pure `staleManagedIPs`) and deactivates the stragglers. `AppModel` runs one global sweep at startup; at a fresh launch nothing is running, so the live set is empty and every leftover is cleared — the design's "clean slate each launch."

**Tech Stack:** Swift 6 strict concurrency (`actor LoopbackCoordinator`, `@MainActor AppModel`/`ProjectStore`), Swift Testing, `NSXPCConnection` (helper read), DI via the `LoopbackProvisioner` protocol with fakes.

---

## Context for the implementer

You have **not** seen this codebase. Key facts:

- **Sprout** is a Swift Package (macOS 14+): `SproutEngine` (library, all real logic), `sprout` (CLI), `SproutApp` (SwiftUI app), `SproutHelper` (root daemon), `CSproutXPC` (C shim).
- This is the final slice of the per-workspace loopback feature (`127.0.10.N` IPs, one per git worktree, reachable as `<process>.<project>.localhost`). Prior plans built: the engine seam + refcount wiring (2b-1), the privileged XPC helper + helper-boot sweep (2b-2), and the signing/bundling pipeline (2b-3). This plan (2b-4) adds the **app-launch** crash-recovery sweep — the counterpart to the helper-boot sweep.
- The feature is **off by default** (`UserDefaults` key `loopbackEnabled`, default false). When off, everything here is a guarded no-op and production keeps binding `127.0.0.1`. Do not turn it on.
- **Why two sweeps?** The helper-boot sweep (already shipped, `PrivilegedEffects.clearAllManaged()` at daemon `RunAtLoad`) handles reboots. This app-launch sweep handles the app crashing while the helper keeps running: aliases/hosts outlive the crashed app, so on relaunch we reconcile and drop the orphans.

### Conventions (a pre-commit hook enforces ALL THREE; commit fails otherwise)
1. `swift format lint -r Sources Tests` (strict; 4-space indent, ~100 col soft limit, compact hanging-indent for wrapped calls)
2. `swift build` — must be WARNING-FREE
3. `swift test`

Never `--no-verify` / `git commit --amend`. Do NOT run `swift format format -i` (it rewraps the intentional style). Use **Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`), NOT XCTest. Under the strict formatter `#expect` cannot inline a multi-line expression — bind the expected value to a `let` first, then `#expect(actual == expected)`. Comments explain *why*, not *what*; don't add docstrings to unchanged code.

### Existing code you will build on (read these before editing)

`Sources/SproutEngine/Loopback/LoopbackProvisioner.swift` — the seam:
```swift
public protocol LoopbackProvisioner: Sendable {
    func setActive(ip: String, hosts: [String], active: Bool) async throws
}
public struct NoopLoopbackProvisioner: LoopbackProvisioner {
    public init() {}
    public func setActive(ip: String, hosts: [String], active: Bool) async throws {}
}
```

`Sources/SproutEngine/Loopback/LoopbackReaper.swift` — the pure diff (DO NOT reimplement; call it):
```swift
public func staleManagedIPs(managed: [String], live: Set<String>) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for ip in managed where !live.contains(ip) && !seen.contains(ip) {
        seen.insert(ip)
        result.append(ip)
    }
    return result
}
```

`Sources/SproutEngine/Loopback/LoopbackCoordinator.swift` — refcount actor (you add `sweep` here):
```swift
public actor LoopbackCoordinator {
    private let provisioner: LoopbackProvisioner
    private var counts: [String: Int] = [:]
    public init(provisioner: LoopbackProvisioner) { self.provisioner = provisioner }
    public func activate(branch: String, ip: String, hosts: [String]) async throws { ... }
    public func deactivate(branch: String, ip: String, hosts: [String]) async { ... }
}
```

`Sources/SproutEngine/Loopback/HelperProtocol.swift` already declares the XPC read the helper implements:
```swift
func listManaged(reply: @escaping ([String]) -> Void)
```

`Sources/SproutApp/Model/XPCProvisioner.swift` — the production provisioner. It currently implements only `setActive` over a code-sig-pinned `NSXPCConnection`, with a private `OnceResumer` single-fire continuation guard at the bottom of the file.

`Sources/SproutApp/Model/AppModel.swift` — `loadProjects()` builds, per project, `LoopbackCoordinator(provisioner: XPCProvisioner())` when `loopbackEnabled`, else `nil`. `init()` calls `loadProjects()` then `helper.refresh()`.

`Sources/SproutApp/Model/ProjectStore.swift` — `@MainActor` view-model. Holds `let loopback: LoopbackCoordinator`, `loopbackEnabled: Bool`, and `@Published private(set) var workspaces: [WorkspaceItem]` (each `WorkspaceItem` has `record: WorkspaceRecord` with `bindIP: String` and `record.status` of type with a `.running` case). `refresh()` populates `workspaces` from `manager.reconcile()` (reconcile determines real liveness via the process checker).

### Two test fakes implement the protocol — BOTH must gain the new method
- `Tests/SproutEngineTests/Support/FakeLoopbackProvisioner.swift` — `FakeLoopbackProvisioner` (records `setActive` calls, lock-guarded).
- `Tests/SproutAppTests/ProjectStoreLoopbackTests.swift` — `RecordingProvisioner` (same shape, defined inline near the bottom).

### File structure (create / modify)
- Modify: `Sources/SproutEngine/Loopback/LoopbackProvisioner.swift` — add `listManaged()` to protocol + Noop.
- Modify: `Sources/SproutEngine/Loopback/LoopbackCoordinator.swift` — add `sweep(live:)`.
- Modify: `Sources/SproutApp/Model/XPCProvisioner.swift` — implement `listManaged()`; genericize `OnceResumer`.
- Modify: `Sources/SproutApp/Model/ProjectStore.swift` — add `runningBindIPs()` + `sweepStaleLoopback(live:)`.
- Modify: `Sources/SproutApp/Model/AppModel.swift` — run one launch sweep at startup.
- Modify: `Tests/SproutEngineTests/Support/FakeLoopbackProvisioner.swift` — conform + configurable managed list.
- Modify: `Tests/SproutAppTests/ProjectStoreLoopbackTests.swift` — conform `RecordingProvisioner` + add sweep test.
- Create: `Tests/SproutEngineTests/LoopbackSweepTests.swift` — coordinator sweep tests.

---

### Task 1: Add `listManaged()` to the provisioner seam

**Files:**
- Modify: `Sources/SproutEngine/Loopback/LoopbackProvisioner.swift`
- Modify: `Tests/SproutEngineTests/Support/FakeLoopbackProvisioner.swift`
- Modify: `Tests/SproutAppTests/ProjectStoreLoopbackTests.swift` (RecordingProvisioner only — the sweep TEST comes in Task 4)
- Test: `Tests/SproutEngineTests/LoopbackProvisionerTests.swift` (add one case)

- [ ] **Step 1: Write the failing test**

Append to `Tests/SproutEngineTests/LoopbackProvisionerTests.swift` (inside the existing suite — match the file's existing `@Suite`/`@Test` style; if tests are free `@Test func`s at file scope, add a free one):

```swift
@Test func noopListManagedReturnsEmpty() async throws {
    let p = NoopLoopbackProvisioner()
    let managed = try await p.listManaged()
    #expect(managed.isEmpty)
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter noopListManagedReturnsEmpty`
Expected: FAIL — `value of type 'NoopLoopbackProvisioner' has no member 'listManaged'` (compile error).

- [ ] **Step 3: Add the protocol method + Noop impl**

In `Sources/SproutEngine/Loopback/LoopbackProvisioner.swift`, change the protocol and Noop:

```swift
/// Installs or removes a loopback alias plus its `/etc/hosts` entries for one
/// workspace IP. The real implementation talks to a privileged helper over XPC;
/// engine and tests depend only on this protocol.
public protocol LoopbackProvisioner: Sendable {
    func setActive(ip: String, hosts: [String], active: Bool) async throws
    /// IPs the helper currently manages (its `/etc/hosts` block). Used by the
    /// launch sweep to find aliases a crashed app left behind.
    func listManaged() async throws -> [String]
}

/// Default no-op. Wired into the app until the XPC helper exists, so behavior is
/// unchanged (no aliases created; workspaces keep binding 127.0.0.1).
public struct NoopLoopbackProvisioner: LoopbackProvisioner {
    public init() {}
    public func setActive(ip: String, hosts: [String], active: Bool) async throws {}
    public func listManaged() async throws -> [String] { [] }
}
```
Leave `loopbackHostnames`/`hostnameSlug` in that file unchanged.

- [ ] **Step 4: Update the engine test fake**

In `Tests/SproutEngineTests/Support/FakeLoopbackProvisioner.swift`, add a configurable managed list and the method. Insert the storage next to `_calls`, a setter next to `setFailNext`, and the method after `setActive`:

```swift
    private var _managed: [String] = []

    func setManaged(_ ips: [String]) { lock.withLock { _managed = ips } }

    func listManaged() async throws -> [String] {
        lock.withLock { _managed }
    }
```

- [ ] **Step 5: Update the app test fake**

In `Tests/SproutAppTests/ProjectStoreLoopbackTests.swift`, give `RecordingProvisioner` the same additions (storage `_managed`, `setManaged(_:)`, and `listManaged()`), mirroring the engine fake exactly so both stay in sync.

- [ ] **Step 6: Run tests + build**

Run: `swift test --filter noopListManagedReturnsEmpty`
Expected: PASS.
Run: `swift build`
Expected: clean, no warnings (XPCProvisioner does NOT yet conform — see note).

> NOTE: `XPCProvisioner` now fails to conform to `LoopbackProvisioner` because it lacks `listManaged()`. If `swift build` fails on that, that's expected — Task 3 adds it. To keep each task's build green, add a **temporary** stub to `XPCProvisioner` in THIS task and replace it in Task 3:
> ```swift
> func listManaged() async throws -> [String] { [] }
> ```
> Place it right after `setActive`. Task 3 replaces the body with the real XPC call.

- [ ] **Step 7: Commit**

```bash
git add Sources/SproutEngine/Loopback/LoopbackProvisioner.swift Sources/SproutApp/Model/XPCProvisioner.swift Tests/SproutEngineTests/Support/FakeLoopbackProvisioner.swift Tests/SproutAppTests/ProjectStoreLoopbackTests.swift Tests/SproutEngineTests/LoopbackProvisionerTests.swift
git commit -m "feat: add listManaged() to LoopbackProvisioner seam"
```

---

### Task 2: `LoopbackCoordinator.sweep(live:)`

**Files:**
- Modify: `Sources/SproutEngine/Loopback/LoopbackCoordinator.swift`
- Test: `Tests/SproutEngineTests/LoopbackSweepTests.swift` (create)

The sweep is stateless w.r.t. refcounts — it acts on the helper's global managed set, not `counts`. Best-effort, never throws (mirrors `deactivate`): a failed read yields no teardowns; a failed teardown is skipped.

- [ ] **Step 1: Write the failing tests**

Create `Tests/SproutEngineTests/LoopbackSweepTests.swift`:

```swift
import Testing

@testable import SproutEngine

@Suite struct LoopbackSweepTests {
    @Test func sweepDeactivatesOnlyStaleIPs() async {
        let fake = FakeLoopbackProvisioner()
        fake.setManaged(["127.0.10.1", "127.0.10.2", "127.0.10.3"])
        let coord = LoopbackCoordinator(provisioner: fake)

        await coord.sweep(live: ["127.0.10.2"])

        let expected: [FakeLoopbackProvisioner.Call] = [
            .init(ip: "127.0.10.1", hosts: [], active: false),
            .init(ip: "127.0.10.3", hosts: [], active: false),
        ]
        #expect(fake.calls == expected)
    }

    @Test func sweepWithNothingStaleDoesNothing() async {
        let fake = FakeLoopbackProvisioner()
        fake.setManaged(["127.0.10.5"])
        let coord = LoopbackCoordinator(provisioner: fake)

        await coord.sweep(live: ["127.0.10.5"])

        #expect(fake.calls.isEmpty)
    }

    @Test func sweepEmptyLiveClearsEverything() async {
        let fake = FakeLoopbackProvisioner()
        fake.setManaged(["127.0.10.8", "127.0.10.9"])
        let coord = LoopbackCoordinator(provisioner: fake)

        await coord.sweep(live: [])

        let expected: [FakeLoopbackProvisioner.Call] = [
            .init(ip: "127.0.10.8", hosts: [], active: false),
            .init(ip: "127.0.10.9", hosts: [], active: false),
        ]
        #expect(fake.calls == expected)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter LoopbackSweepTests`
Expected: FAIL — `value of type 'LoopbackCoordinator' has no member 'sweep'`.

- [ ] **Step 3: Implement `sweep`**

In `Sources/SproutEngine/Loopback/LoopbackCoordinator.swift`, add this method inside the actor, after `deactivate`:

```swift
    /// Crash-recovery sweep: tear down every managed IP that no longer backs a
    /// live workspace. Stateless w.r.t. `counts` — it reconciles the helper's
    /// global `/etc/hosts` block against `live`, not this run's refcounts. Best
    /// effort: a failed read or teardown is swallowed (the helper-boot sweep is
    /// the backstop).
    public func sweep(live: Set<String>) async {
        let managed = (try? await provisioner.listManaged()) ?? []
        for ip in staleManagedIPs(managed: managed, live: live) {
            try? await provisioner.setActive(ip: ip, hosts: [], active: false)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LoopbackSweepTests`
Expected: PASS (3 tests).
Run: `swift build`
Expected: clean, no warnings.

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Loopback/LoopbackCoordinator.swift Tests/SproutEngineTests/LoopbackSweepTests.swift
git commit -m "feat: add LoopbackCoordinator.sweep for crash-recovery"
```

---

### Task 3: `XPCProvisioner.listManaged()` over XPC

**Files:**
- Modify: `Sources/SproutApp/Model/XPCProvisioner.swift`

The helper exposes `listManaged(reply: @escaping ([String]) -> Void)` (no error arg). Mirror the existing `setActive` connection setup (pinned requirement, `.privileged`, single-fire continuation). The existing `OnceResumer` is hard-typed to `CheckedContinuation<Void, Error>`; genericize it so both `setActive` (Void) and `listManaged` (`[String]`) can use it.

No automated test — this is real XPC to a signed root daemon, exercised only via the manual checklist. Verify by build + lint.

- [ ] **Step 1: Replace the Task-1 stub with the real implementation**

In `Sources/SproutApp/Model/XPCProvisioner.swift`, replace the temporary stub
```swift
    func listManaged() async throws -> [String] { [] }
```
with:
```swift
    func listManaged() async throws -> [String] {
        let conn = NSXPCConnection(
            machServiceName: sproutHelperMachServiceName,
            options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: SproutHelperProtocol.self)
        conn.setCodeSigningRequirement(helperRequirement)
        conn.resume()
        defer { conn.invalidate() }

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[String], Error>) in
            let once = OnceResumer(continuation)
            let proxy =
                conn.remoteObjectProxyWithErrorHandler { err in
                    once.resume(throwing: ProvisionError.helperRejected("\(err)"))
                } as? SproutHelperProtocol
            guard let proxy else {
                once.resume(throwing: ProvisionError.helperUnavailable)
                return
            }
            proxy.listManaged { ips in once.resume(returning: ips) }
        }
    }
```

- [ ] **Step 2: Genericize `OnceResumer`**

The current `OnceResumer` (bottom of the file) is:
```swift
private final class OnceResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Void) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(returning: ())
        continuation = nil
    }

    func resume(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
```
Replace it with a generic version:
```swift
/// Ensures a `CheckedContinuation` resumes exactly once. The XPC error handler
/// and the reply block can both fire (e.g. a connection drop after a reply); the
/// first call wins and the rest are no-ops. Lock-guarded, hence
/// `@unchecked Sendable`.
private final class OnceResumer<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(returning: value)
        continuation = nil
    }

    func resume(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
```
The existing `setActive` already does `let once = OnceResumer(continuation)` and `once.resume(returning: ())` — generic inference makes that `OnceResumer<Void>` with no call-site change needed. Confirm `setActive` still compiles unchanged.

- [ ] **Step 3: Build + lint**

Run: `swift build`
Expected: clean, no warnings (both `setActive` and `listManaged` conform; `XPCProvisioner` now fully satisfies `LoopbackProvisioner`).
Run: `swift format lint -r Sources Tests`
Expected: no errors.
Run: `swift test`
Expected: still green (no behavior change to tested paths).

- [ ] **Step 4: Commit**

```bash
git add Sources/SproutApp/Model/XPCProvisioner.swift
git commit -m "feat: implement XPCProvisioner.listManaged over XPC"
```

---

### Task 4: Wire the launch sweep in ProjectStore + AppModel

**Files:**
- Modify: `Sources/SproutApp/Model/ProjectStore.swift`
- Modify: `Sources/SproutApp/Model/AppModel.swift`
- Test: `Tests/SproutAppTests/ProjectStoreLoopbackTests.swift` (add cases)

`ProjectStore` exposes the IPs of its currently-live workspaces; `AppModel` aggregates them across projects and runs one sweep through a dedicated coordinator. At a fresh launch no workspace is live, so the live set is empty and all leftovers are cleared.

- [ ] **Step 1: Write the failing tests**

In `Tests/SproutAppTests/ProjectStoreLoopbackTests.swift`, add (inside the existing suite, using the existing `makeLoopbackStore` helper):

```swift
@Test @MainActor func sweepClearsManagedIPsNotLive() async {
    let prov = RecordingProvisioner()
    prov.setManaged(["127.0.10.1", "127.0.10.2"])
    let store = makeLoopbackStore(
        prov: prov, enabled: true,
        processes: [ProcessConfig(name: "web", command: "x", port: 3000)])

    await store.sweepStaleLoopback(live: ["127.0.10.2"])

    let expected: [RecordingProvisioner.Call] = [
        .init(ip: "127.0.10.1", hosts: [], active: false)
    ]
    #expect(prov.calls == expected)
}

@Test @MainActor func sweepIsNoOpWhenDisabled() async {
    let prov = RecordingProvisioner()
    prov.setManaged(["127.0.10.1"])
    let store = makeLoopbackStore(
        prov: prov, enabled: false,
        processes: [ProcessConfig(name: "web", command: "x", port: 3000)])

    await store.sweepStaleLoopback(live: [])

    #expect(prov.calls.isEmpty)
}
```

> Check `makeLoopbackStore`'s signature in the file before using it — it builds a `ProjectStore` with a `LoopbackCoordinator(provisioner: prov)` and the given `enabled` flag. If it does not already inject the coordinator from `prov`, adjust the test to construct the store the same way the existing passing tests in this file do.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter "sweepClearsManagedIPsNotLive"`
Expected: FAIL — `value of type 'ProjectStore' has no member 'sweepStaleLoopback'`.

- [ ] **Step 3: Add `runningBindIPs()` + `sweepStaleLoopback(live:)` to ProjectStore**

In `Sources/SproutApp/Model/ProjectStore.swift`, add near the other loopback helpers (after `deactivateLoopback`):

```swift
    /// Bind IPs of this project's workspaces that are actually running, for the
    /// launch sweep's "live" set. Empty when the feature is off or nothing runs.
    func runningBindIPs() -> [String] {
        guard loopbackEnabled else { return [] }
        return workspaces
            .filter { $0.record.status == .running }
            .map { $0.record.bindIP }
    }

    /// Tear down managed loopback aliases this project no longer backs (launch
    /// crash-recovery). No-op when the feature is disabled. `live` is the global
    /// set of running bind IPs so a straggler from another project isn't cleared
    /// while it is genuinely in use.
    func sweepStaleLoopback(live: Set<String>) async {
        guard loopbackEnabled else { return }
        await loopback.sweep(live: live)
    }
```

- [ ] **Step 4: Run ProjectStore tests to verify they pass**

Run: `swift test --filter "sweepClearsManagedIPsNotLive"` and `--filter "sweepIsNoOpWhenDisabled"`
Expected: PASS.

- [ ] **Step 5: Run the global sweep once at app startup**

In `Sources/SproutApp/Model/AppModel.swift`, add a method and call it from `init()`. After `loadProjects()` populates `projects`, the live set is empty (nothing started yet), so this clears all leftovers — the design's clean slate.

Add the method:
```swift
    /// One-shot crash-recovery sweep at launch: ask the helper what it still
    /// manages and drop aliases no live workspace backs. Runs through a dedicated
    /// coordinator (the per-project ones are for refcounting). No-op when the
    /// loopback feature is disabled.
    private func sweepStaleLoopbackAliases() async {
        guard loopbackEnabled else { return }
        let live = Set(projects.flatMap { $0.runningBindIPs() })
        let coordinator = LoopbackCoordinator(provisioner: XPCProvisioner())
        await coordinator.sweep(live: live)
    }
```

Change `init()` to kick it off (after `helper.refresh()`):
```swift
    init() {
        registry = ProjectRegistry.load(from: SproutPaths.registryFile)
        loadProjects()
        helper.refresh()
        Task { await sweepStaleLoopbackAliases() }
    }
```

- [ ] **Step 6: Build + full test + lint**

Run: `swift build` → clean, no warnings.
Run: `swift test` → all green.
Run: `swift format lint -r Sources Tests` → no errors.

- [ ] **Step 7: Commit**

```bash
git add Sources/SproutApp/Model/ProjectStore.swift Sources/SproutApp/Model/AppModel.swift Tests/SproutAppTests/ProjectStoreLoopbackTests.swift
git commit -m "feat: run loopback launch sweep on app startup"
```

---

### Task 5: Verify behavior-unchanged-when-disabled + update manual checklist

**Files:**
- Modify: `docs/MANUAL-VERIFICATION-2b-3.md` (the boot-sweep checklist already covers reboots; add the app-crash case)

No new code. Confirm the off-by-default invariant holds and document the new manual case.

- [ ] **Step 1: Confirm the feature stays off in production**

Run: `swift test`
Expected: full suite green (should be the prior count + the 6 new tests from Tasks 1–4).
Grep that no production call site enables the flag:
Run: `grep -rn "loopbackEnabled: true" Sources` — expected: no matches (only `UserDefaults`-driven). The `defaults write ... loopbackEnabled` opt-in is the only way it turns on.

- [ ] **Step 2: Add the app-launch case to the manual checklist**

In `docs/MANUAL-VERIFICATION-2b-3.md`, under the `## Boot sweep` section, append a sibling case:

```markdown
## App-launch sweep (crash recovery, helper still running)
- [ ] With aliases/hosts present from a running workspace, force-quit the app
      (do NOT reboot — the helper stays loaded).
- [ ] Relaunch the app. On startup the stale `127.0.10.N` aliases and their
      SPROUT hosts lines are cleared (nothing is running yet → clean slate).
- [ ] A workspace whose process genuinely survived the crash (pid still alive)
      keeps its alias — its IP is in the live set, so the sweep skips it.
```

- [ ] **Step 3: Commit**

```bash
git add docs/MANUAL-VERIFICATION-2b-3.md
git commit -m "docs: add app-launch sweep to manual verification checklist"
```

---

## Self-Review

**Spec coverage** (design §365 "Crash recovery / stale cleanup" item 1 — app-launch sweep):
- `listManaged()` read on the seam (helper already exposes it over XPC) → Task 1 (protocol/Noop/fakes), Task 3 (XPCProvisioner).
- Diff against live workspaces via `staleManagedIPs` → Task 2 (`sweep`), reusing the existing pure function.
- "Clean slate each launch (nothing running yet)" → Task 4 (`AppModel` startup sweep with empty live set at fresh launch).
- Survivor protection (a still-alive process keeps its alias) → Task 4 `runningBindIPs()` filters on reconciled `.running`, feeding the live set.
- Item 2 (helper-boot sweep) is already shipped in 2b-2/2b-3 — out of scope here.
- Off-by-default invariant preserved → guards in `runningBindIPs`/`sweepStaleLoopback`/`sweepStaleLoopbackAliases`; Task 5 verifies.

**Placeholder scan:** None. The Task-1 temporary `XPCProvisioner` stub is explicitly flagged as temporary and replaced in Task 3 (called out in both tasks).

**Type/name consistency:** `listManaged()` signature `() async throws -> [String]` is identical across protocol, Noop, both fakes, and XPCProvisioner. `sweep(live: Set<String>)` on `LoopbackCoordinator` matches the call in `ProjectStore.sweepStaleLoopback(live:)` and `AppModel.sweepStaleLoopbackAliases`. `staleManagedIPs(managed:live:)` called with the exact existing signature. `setActive(ip:hosts:active:)` teardown call uses `hosts: []` (consistent with how `SproutHostsBlock.remove` keys removal by IP). `OnceResumer` genericized to `OnceResumer<Value>`; `setActive`'s existing `resume(returning: ())` resolves to `OnceResumer<Void>` with no call-site edit.

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-06-06-loopback-launch-sweep.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — fresh subagent per task, two-stage review between tasks. Tasks 1, 2, 4 are TDD with real tests; Task 3 is XPC (build/lint-verified); Task 5 is verification + docs.

**2. Inline Execution** — execute in this session via executing-plans with checkpoints.

**Which approach?**
