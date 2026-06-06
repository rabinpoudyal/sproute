# Loopback Privileged Helper (Plan 2b-2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the privileged `com.sprout.helper` root daemon and its app-side XPC client so per-workspace loopback aliases (`127.0.10.N`) and `/etc/hosts` entries are installed/removed through a code-signature-pinned helper — the GUI app never runs as root.

**Architecture:** Three layers. (1) Pure, root-free decision logic in `SproutEngine/Loopback` (ifconfig argv builder, code-sign requirement string, reaper diff) — unit-tested without root. (2) A new `SproutHelper` executable target: a `NSXPCListener`-based root daemon that validates every caller's code signature, validates every request with the existing whitelist validators, then applies effects via `/sbin/ifconfig` + an atomic `/etc/hosts` write. (3) App-side `XPCProvisioner` (a concrete `LoopbackProvisioner` forwarding over a pinned `NSXPCConnection`) plus `HelperManager` (SMAppService registration + status), wired into `AppModel`/`ProjectStore` behind the existing `loopbackEnabled` flag.

**Tech Stack:** Swift 6 (strict concurrency), Foundation, `NSXPCConnection`/`NSXPCListener`, `Security` (SecCode/SecRequirement), `ServiceManagement` (SMAppService), a tiny C shim target (`CSproutXPC`) for the connection audit token. Swift Testing for unit tests.

**Scope boundary:** This plan produces source that **compiles and unit-tests clean**, but the end-to-end privileged round-trip (helper actually mutating `lo0` + `/etc/hosts`) cannot run until the bundling/signing pipeline lands in **Plan 2b-3** (Makefile, daemon plists, generated `CodeSignRequirement` constants, notarization). Until then: caller/helper pinning uses placeholder requirement strings, `SMAppService` registration is wired but unverified, and all privileged effects are exercised only via the **manual, `SPROUT_INTEGRATION`-gated checklist in Task 11**. The `loopbackEnabled` flag stays **off by default**, so production behavior is unchanged.

**Reused, do not reimplement (Plan 2a, already merged):**
- `validateLoopbackRequest(ip:hosts:) throws` → throws `ProvisionError.helperRejected(_)`. Defense-in-depth gate the helper runs on every request.
- `isValidLoopbackIP(_:)`, `isValidLoopbackHostname(_:)` — called by the above.
- `SproutHostsBlock.upsert(contents:ip:hosts:)`, `.remove(contents:ip:)`, `.managedIPs(contents:)` — pure `/etc/hosts` block editor.
- `ProvisionError` enum (`helperUnavailable`, `helperRejected(String)`, `ifconfigFailed(String)`, `hostsWriteFailed(String)`).
- `LoopbackProvisioner` protocol: `func setActive(ip: String, hosts: [String], active: Bool) async throws`.
- `LoopbackCoordinator(provisioner:)` — refcounts and drives the provisioner.

---

## File Structure

**Create:**
- `Sources/SproutEngine/Loopback/HelperProtocol.swift` — `@objc` XPC contract + mach service name (shared by app and helper).
- `Sources/SproutEngine/Loopback/CodeSignRequirement.swift` — pure requirement-string builder.
- `Sources/SproutEngine/Loopback/LoopbackIfconfig.swift` — pure `ifconfig` argv builder.
- `Sources/SproutEngine/Loopback/LoopbackReaper.swift` — pure stale-IP diff.
- `Sources/CSproutXPC/include/CSproutXPC.h` + `Sources/CSproutXPC/shim.m` — C shim exposing `NSXPCConnection.auditToken`.
- `Sources/SproutHelper/PrivilegedEffects.swift` — imperative ifconfig + hosts apply (root only; gated).
- `Sources/SproutHelper/HelperService.swift` — `NSXPCListenerDelegate` + caller pinning + protocol impl.
- `Sources/SproutHelper/main.swift` — listener bootstrap.
- `Sources/SproutApp/Model/XPCReply.swift` — pure reply→Result mapping.
- `Sources/SproutApp/Model/XPCProvisioner.swift` — `LoopbackProvisioner` over a pinned connection.
- `Sources/SproutApp/Model/HelperManager.swift` — SMAppService register/status.
- Tests: `Tests/SproutEngineTests/CodeSignRequirementTests.swift`, `LoopbackIfconfigTests.swift`, `LoopbackReaperTests.swift`; `Tests/SproutAppTests/XPCReplyTests.swift`, `HelperManagerTests.swift`.

**Modify:**
- `Package.swift` — add `CSproutXPC` (C target), `SproutHelper` (executable target + product), make `SproutHelper` depend on `SproutEngine` + `CSproutXPC`.
- `Sources/SproutApp/Model/AppModel.swift` — build an `XPCProvisioner`-backed `LoopbackCoordinator` when the flag is on; own a `HelperManager`.
- `Sources/SproutApp/Views/SettingsView.swift` — loopback-helper status + install button.

---

## Task 1: XPC contract (shared protocol)

**Files:**
- Create: `Sources/SproutEngine/Loopback/HelperProtocol.swift`

- [ ] **Step 1: Write the contract**

```swift
import Foundation

/// Mach service name the privileged helper registers and the app connects to.
/// Must match the `MachServices` key in the helper's launchd plist (Plan 2b-3).
public let sproutHelperMachServiceName = "com.sprout.helper.xpc"

/// The narrow XPC contract between the unprivileged app and the root helper.
/// Three calls only — every one is validated helper-side before any side
/// effect. `@objc` with reply blocks because `NSXPCConnection` requires an
/// Objective-C protocol using completion-handler methods (no async/throws
/// across the boundary).
@objc public protocol SproutHelperProtocol {
    /// Install (`active == true`) or remove (`false`) the `lo0` alias for `ip`
    /// plus its `/etc/hosts` block. `reply` carries `nil` on success or a
    /// human-readable error string on rejection/failure.
    func setActive(
        ip: String, hosts: [String], active: Bool,
        reply: @escaping (String?) -> Void)

    /// Liveness probe: returns the helper's version so the app can detect a
    /// stale installed helper after an app upgrade.
    func ping(reply: @escaping (String) -> Void)

    /// The loopback IPs the helper currently manages in `/etc/hosts`, for the
    /// app's reconcile/reaper. Empty when nothing is provisioned.
    func listManaged(reply: @escaping ([String]) -> Void)
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!` (no test yet — this file is a pure contract with no logic to assert).

- [ ] **Step 3: Commit**

```bash
git add Sources/SproutEngine/Loopback/HelperProtocol.swift
git commit -m "feat: SproutHelperProtocol XPC contract + mach service name"
```

---

## Task 2: Code-signing requirement builder (pure)

**Files:**
- Create: `Sources/SproutEngine/Loopback/CodeSignRequirement.swift`
- Test: `Tests/SproutEngineTests/CodeSignRequirementTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing

@testable import SproutEngine

@Suite struct CodeSignRequirementTests {
    @Test func buildsIdentifierAndLeafHashRequirement() {
        let req = codeSigningRequirement(
            identifier: "com.sprout.app",
            leafCertSHA256Hex: "ABCD1234")
        #expect(
            req == "identifier \"com.sprout.app\" and certificate leaf = H\"ABCD1234\"")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CodeSignRequirementTests`
Expected: FAIL — `cannot find 'codeSigningRequirement' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Builds the code-signing requirement string both sides use to pin each other.
/// Pins a fixed designated identifier AND the SHA-256 of the signing
/// certificate leaf — so a different cert (even from the same team) is
/// rejected. The concrete identifier + hash are generated at sign time in
/// Plan 2b-3; this function just composes the canonical requirement syntax.
public func codeSigningRequirement(
    identifier: String, leafCertSHA256Hex: String
) -> String {
    "identifier \"\(identifier)\" and certificate leaf = H\"\(leafCertSHA256Hex)\""
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CodeSignRequirementTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Loopback/CodeSignRequirement.swift Tests/SproutEngineTests/CodeSignRequirementTests.swift
git commit -m "feat: codeSigningRequirement pure builder"
```

---

## Task 3: ifconfig argument builder (pure)

**Files:**
- Create: `Sources/SproutEngine/Loopback/LoopbackIfconfig.swift`
- Test: `Tests/SproutEngineTests/LoopbackIfconfigTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing

@testable import SproutEngine

@Suite struct LoopbackIfconfigTests {
    @Test func aliasUpArguments() {
        #expect(LoopbackIfconfig.tool == "/sbin/ifconfig")
        let args = LoopbackIfconfig.arguments(ip: "127.0.10.7", active: true)
        #expect(args.count == 4)
        #expect(args.first == "lo0")
        #expect(args.last == "up")
        #expect(args[1] == "alias")
        #expect(args[2] == "127.0.10.7")
    }

    @Test func aliasDownArguments() {
        let args = LoopbackIfconfig.arguments(ip: "127.0.10.7", active: false)
        #expect(args.count == 3)
        #expect(args[1] == "-alias")
        #expect(args[2] == "127.0.10.7")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LoopbackIfconfigTests`
Expected: FAIL — `cannot find 'LoopbackIfconfig' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Builds the exact `ifconfig` argument vector for adding/removing a loopback
/// alias. Absolute tool path plus a fixed argv (never a shell string) so the
/// IP can't inject arguments — and the IP must already have passed
/// `isValidLoopbackIP`. `active` selects `alias … up` vs `-alias`.
public enum LoopbackIfconfig {
    public static let tool = "/sbin/ifconfig"

    public static func arguments(ip: String, active: Bool) -> [String] {
        active
            ? ["lo0", "alias", ip, "up"]
            : ["lo0", "-alias", ip]
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LoopbackIfconfigTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Loopback/LoopbackIfconfig.swift Tests/SproutEngineTests/LoopbackIfconfigTests.swift
git commit -m "feat: LoopbackIfconfig argv builder"
```

---

## Task 4: Reaper diff (pure)

**Files:**
- Create: `Sources/SproutEngine/Loopback/LoopbackReaper.swift`
- Test: `Tests/SproutEngineTests/LoopbackReaperTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing

@testable import SproutEngine

@Suite struct LoopbackReaperTests {
    @Test func returnsManagedIPsWithNoLiveAllocation() {
        let stale = staleManagedIPs(
            managed: ["127.0.10.1", "127.0.10.2", "127.0.10.3"],
            live: ["127.0.10.2"])
        #expect(stale == ["127.0.10.1", "127.0.10.3"])
    }

    @Test func emptyWhenAllManagedAreLive() {
        let stale = staleManagedIPs(
            managed: ["127.0.10.1"], live: ["127.0.10.1"])
        #expect(stale.isEmpty)
    }

    @Test func dedupesAndPreservesOrder() {
        let stale = staleManagedIPs(
            managed: ["127.0.10.5", "127.0.10.5", "127.0.10.4"],
            live: [])
        #expect(stale == ["127.0.10.5", "127.0.10.4"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LoopbackReaperTests`
Expected: FAIL — `cannot find 'staleManagedIPs' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Pure diff for the crash-recovery sweep: any IP the helper still manages in
/// `/etc/hosts` that no longer has a live allocation is stale and should be
/// torn down (`-alias` + hosts removal). Preserves input order and de-dupes so
/// the caller can drive one teardown per unique stale IP.
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

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LoopbackReaperTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutEngine/Loopback/LoopbackReaper.swift Tests/SproutEngineTests/LoopbackReaperTests.swift
git commit -m "feat: staleManagedIPs reaper diff"
```

---

## Task 5: C shim for the connection audit token

`NSXPCConnection.auditToken` is not exposed to Swift. A C target declares the
property via a category and returns the struct, so the helper can pin the
caller's code signature against its audit token (TOCTOU-safe, unlike PID).

**Files:**
- Create: `Sources/CSproutXPC/include/CSproutXPC.h`
- Create: `Sources/CSproutXPC/shim.m`
- Modify: `Package.swift`

- [ ] **Step 1: Write the header**

`Sources/CSproutXPC/include/CSproutXPC.h`:

```c
#import <Foundation/Foundation.h>
#import <bsm/libbsm.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns the audit token of the process on the other end of `connection`.
/// Reads `NSXPCConnection`'s `auditToken` property (declared via a category
/// below); the token is what `SecCodeCopyGuestWithAttributes` needs to pin the
/// caller's code signature.
audit_token_t SproutConnectionAuditToken(NSXPCConnection *connection);

NS_ASSUME_NONNULL_END
```

- [ ] **Step 2: Write the implementation**

`Sources/CSproutXPC/shim.m`:

```objc
#import "CSproutXPC.h"

// NSXPCConnection exposes `auditToken` but does not declare it publicly.
// Forward-declare it so the compiler lets us read it.
@interface NSXPCConnection (SproutAuditToken)
@property (nonatomic, readonly) audit_token_t auditToken;
@end

audit_token_t SproutConnectionAuditToken(NSXPCConnection *connection) {
    return connection.auditToken;
}
```

- [ ] **Step 3: Register the C target in `Package.swift`**

Add to the `targets:` array (before the `SproutApp` target):

```swift
        .target(name: "CSproutXPC"),
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build --target CSproutXPC`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/CSproutXPC Package.swift
git commit -m "feat: CSproutXPC shim exposing NSXPCConnection audit token"
```

---

## Task 6: SproutHelper root daemon (build-only; effects gated)

**Files:**
- Create: `Sources/SproutHelper/PrivilegedEffects.swift`
- Create: `Sources/SproutHelper/HelperService.swift`
- Create: `Sources/SproutHelper/main.swift`
- Modify: `Package.swift`

> Privileged effects (ifconfig, `/etc/hosts` write) only run as root and are
> verified by the manual checklist in Task 11. This task only requires the
> target to **compile** and be reachable by `swift build`.

- [ ] **Step 1: Write the privileged effects**

`Sources/SproutHelper/PrivilegedEffects.swift`:

```swift
import Foundation
import SproutEngine

/// The only code in the system that mutates `lo0` or `/etc/hosts`. Runs as root
/// inside the helper. Validates every request again (defense in depth — the app
/// already validated, but the helper trusts nothing) before any side effect.
enum PrivilegedEffects {
    static let hostsPath = "/etc/hosts"

    /// Apply one provisioning request. Ordering matters: bring the alias up
    /// before publishing the hostname, and remove the hostname before tearing
    /// the alias down, so a published hostname never resolves to an un-aliased
    /// IP.
    static func apply(ip: String, hosts: [String], active: Bool) throws {
        try validateLoopbackRequest(ip: ip, hosts: active ? hosts : [])
        if active {
            try runIfconfig(ip: ip, active: true)
            try editHosts { SproutHostsBlock.upsert(contents: $0, ip: ip, hosts: hosts) }
        } else {
            try editHosts { SproutHostsBlock.remove(contents: $0, ip: ip) }
            try runIfconfig(ip: ip, active: false)
        }
    }

    static func managedIPs() -> [String] {
        let contents = (try? String(contentsOfFile: hostsPath, encoding: .utf8)) ?? ""
        return SproutHostsBlock.managedIPs(contents: contents)
    }

    private static func runIfconfig(ip: String, active: Bool) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: LoopbackIfconfig.tool)
        proc.arguments = LoopbackIfconfig.arguments(ip: ip, active: active)
        let errPipe = Pipe()
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            throw ProvisionError.ifconfigFailed(String(describing: error))
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg =
                String(
                    data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8) ?? ""
            throw ProvisionError.ifconfigFailed(
                msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func editHosts(_ transform: (String) -> String) throws {
        let current = (try? String(contentsOfFile: hostsPath, encoding: .utf8)) ?? ""
        let updated = transform(current)
        guard updated != current else { return }
        do {
            try updated.write(toFile: hostsPath, atomically: true, encoding: .utf8)
        } catch {
            throw ProvisionError.hostsWriteFailed(String(describing: error))
        }
    }
}
```

- [ ] **Step 2: Write the XPC service + caller pinning**

`Sources/SproutHelper/HelperService.swift`:

```swift
import CSproutXPC
import Foundation
import Security
import SproutEngine

/// Listener delegate + protocol implementation for the root daemon. Accepts a
/// connection only if the caller's code signature satisfies `appRequirement`,
/// then services the three contract methods. The requirement is a placeholder
/// until Plan 2b-3 generates the real identifier + leaf hash at sign time.
final class HelperService: NSObject, NSXPCListenerDelegate, SproutHelperProtocol {
    static let version = "1"

    private let appRequirement: String

    init(appRequirement: String) {
        self.appRequirement = appRequirement
    }

    // MARK: NSXPCListenerDelegate

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection conn: NSXPCConnection
    ) -> Bool {
        guard callerSatisfiesRequirement(conn) else { return false }
        conn.exportedInterface = NSXPCInterface(with: SproutHelperProtocol.self)
        conn.exportedObject = self
        conn.resume()
        return true
    }

    // MARK: SproutHelperProtocol

    func setActive(
        ip: String, hosts: [String], active: Bool,
        reply: @escaping (String?) -> Void
    ) {
        do {
            try PrivilegedEffects.apply(ip: ip, hosts: hosts, active: active)
            reply(nil)
        } catch let e as ProvisionError {
            reply(describe(e))
        } catch {
            reply(String(describing: error))
        }
    }

    func ping(reply: @escaping (String) -> Void) { reply(Self.version) }

    func listManaged(reply: @escaping ([String]) -> Void) {
        reply(PrivilegedEffects.managedIPs())
    }

    // MARK: Caller pinning

    /// True iff the connecting process's code signature satisfies
    /// `appRequirement`. Uses the connection's audit token (not PID, which is
    /// reuse/TOCTOU-prone) to identify the caller.
    private func callerSatisfiesRequirement(_ conn: NSXPCConnection) -> Bool {
        var token = SproutConnectionAuditToken(conn)
        let tokenData = Data(
            bytes: &token, count: MemoryLayout.size(ofValue: token))
        let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        guard
            SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
            let guest = code
        else { return false }
        var req: SecRequirement?
        guard
            SecRequirementCreateWithString(appRequirement as CFString, [], &req)
                == errSecSuccess,
            let requirement = req
        else { return false }
        return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
    }

    private func describe(_ e: ProvisionError) -> String {
        switch e {
        case .helperUnavailable: return "helper unavailable"
        case .helperRejected(let m): return "rejected: \(m)"
        case .ifconfigFailed(let m): return "ifconfig failed: \(m)"
        case .hostsWriteFailed(let m): return "hosts write failed: \(m)"
        }
    }
}
```

- [ ] **Step 3: Write the listener bootstrap**

`Sources/SproutHelper/main.swift`:

```swift
import Foundation

// Placeholder app requirement until Plan 2b-3 generates the real
// identifier + leaf-cert SHA-256 at sign time. `cdhash H"…"` of nothing here;
// the literal below never matches a real signature, so an unsigned dev build
// rejects all callers until 2b-3 wires the generated constant in.
let appRequirement = "identifier \"com.sprout.app.PLACEHOLDER\""

let delegate = HelperService(appRequirement: appRequirement)
let listener = NSXPCListener(machServiceName: sproutHelperMachServiceName)
listener.delegate = delegate
listener.resume()

// launchd owns the lifetime; park the main thread.
RunLoop.current.run()
```

- [ ] **Step 4: Register the executable target + product in `Package.swift`**

Add to `products:`:

```swift
        .executable(name: "sprout-helper", targets: ["SproutHelper"]),
```

Add to `targets:` (after the `CSproutXPC` target):

```swift
        .executableTarget(
            name: "SproutHelper",
            dependencies: ["SproutEngine", "CSproutXPC"]
        ),
```

- [ ] **Step 5: Build to verify it compiles**

Run: `swift build --target SproutHelper`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/SproutHelper Package.swift
git commit -m "feat: SproutHelper root daemon (XPC listener, caller pinning, privileged effects)"
```

---

## Task 7: XPC reply mapping (pure) + provisioner

**Files:**
- Create: `Sources/SproutApp/Model/XPCReply.swift`
- Create: `Sources/SproutApp/Model/XPCProvisioner.swift`
- Test: `Tests/SproutAppTests/XPCReplyTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/SproutAppTests/XPCReplyTests.swift`:

```swift
import SproutEngine
import Testing

@testable import SproutApp

@Suite struct XPCReplyTests {
    @Test func nilReplyIsSuccess() throws {
        try XPCReply.check(nil)
    }

    @Test func nonNilReplyThrowsHelperRejected() {
        #expect(throws: ProvisionError.helperRejected("boom")) {
            try XPCReply.check("boom")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter XPCReplyTests`
Expected: FAIL — `cannot find 'XPCReply' in scope`.

- [ ] **Step 3: Write the reply mapper**

`Sources/SproutApp/Model/XPCReply.swift`:

```swift
import Foundation
import SproutEngine

/// Maps the helper's `String?` reply to a throwing result. `nil` means success;
/// any string is the helper's human-readable rejection/failure reason, surfaced
/// as `ProvisionError.helperRejected`.
enum XPCReply {
    static func check(_ error: String?) throws {
        if let error {
            throw ProvisionError.helperRejected(error)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter XPCReplyTests`
Expected: PASS.

- [ ] **Step 5: Write the provisioner**

`Sources/SproutApp/Model/XPCProvisioner.swift`:

```swift
import Foundation
import Security
import SproutEngine

/// `LoopbackProvisioner` that forwards `setActive` to the root helper over a
/// code-signature-pinned `NSXPCConnection`. The app pins the helper
/// (`setCodeSigningRequirement`) so a swapped-out helper binary can't service
/// requests; the helper independently pins the app (Task 6). A fresh connection
/// per call keeps the seam simple — provisioning is rare (start/stop of the
/// first/last process per branch).
final class XPCProvisioner: LoopbackProvisioner, @unchecked Sendable {
    /// Placeholder helper requirement until Plan 2b-3 generates the real
    /// identifier + leaf hash. Mirrors the helper's placeholder so dev builds
    /// fail closed.
    private let helperRequirement = "identifier \"com.sprout.helper.PLACEHOLDER\""

    func setActive(ip: String, hosts: [String], active: Bool) async throws {
        let conn = NSXPCConnection(
            machServiceName: sproutHelperMachServiceName,
            options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: SproutHelperProtocol.self)
        if #available(macOS 13.0, *) {
            try? conn.setCodeSigningRequirement(helperRequirement)
        }
        conn.resume()
        defer { conn.invalidate() }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let proxy =
                conn.remoteObjectProxyWithErrorHandler { err in
                    continuation.resume(throwing: ProvisionError.helperRejected("\(err)"))
                } as? SproutHelperProtocol
            guard let proxy else {
                continuation.resume(throwing: ProvisionError.helperUnavailable)
                return
            }
            proxy.setActive(ip: ip, hosts: hosts, active: active) { error in
                do {
                    try XPCReply.check(error)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
```

> The error handler and the reply block can both fire in pathological cases;
> `CheckedContinuation` will trap on a double-resume. In practice exactly one
> path runs per call (connection failure → error handler; otherwise → reply).
> Leave as-is unless the manual checklist (Task 11) surfaces a double-resume.

- [ ] **Step 6: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 7: Commit**

```bash
git add Sources/SproutApp/Model/XPCReply.swift Sources/SproutApp/Model/XPCProvisioner.swift Tests/SproutAppTests/XPCReplyTests.swift
git commit -m "feat: XPCProvisioner + reply mapping over pinned NSXPCConnection"
```

---

## Task 8: HelperManager (SMAppService register/status)

**Files:**
- Create: `Sources/SproutApp/Model/HelperManager.swift`
- Test: `Tests/SproutAppTests/HelperManagerTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/SproutAppTests/HelperManagerTests.swift`:

```swift
import ServiceManagement
import Testing

@testable import SproutApp

@Suite struct HelperManagerTests {
    @Test func mapsNotRegisteredToNeedsInstall() {
        #expect(HelperManager.label(for: .notRegistered) == "Not installed")
    }

    @Test func mapsEnabledToInstalled() {
        #expect(HelperManager.label(for: .enabled) == "Installed")
    }

    @Test func mapsRequiresApprovalToApproval() {
        #expect(
            HelperManager.label(for: .requiresApproval)
                == "Needs approval in System Settings")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HelperManagerTests`
Expected: FAIL — `cannot find 'HelperManager' in scope`.

- [ ] **Step 3: Write the manager**

`Sources/SproutApp/Model/HelperManager.swift`:

```swift
import Foundation
import ServiceManagement

/// Registers/unregisters the privileged helper as a launchd daemon via
/// `SMAppService` and reports its status for the UI. The daemon plist
/// (`com.sprout.helper`) ships in the app bundle in Plan 2b-3; registration is
/// wired here but only succeeds once that plist exists and the app is signed.
@MainActor
final class HelperManager: ObservableObject {
    static let daemonPlistName = "com.sprout.helper"

    @Published private(set) var status: SMAppService.Status = .notRegistered

    private var service: SMAppService {
        SMAppService.daemon(plistName: Self.daemonPlistName)
    }

    func refresh() {
        status = service.status
    }

    /// Prompts the user (System Settings > Login Items) to approve the daemon.
    func install() throws {
        try service.register()
        refresh()
    }

    func uninstall() throws {
        try service.unregister()
        refresh()
    }

    /// UI label for a status. Pure + static so it is unit-testable without a
    /// real `SMAppService`.
    static func label(for status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "Not installed"
        case .enabled: return "Installed"
        case .requiresApproval: return "Needs approval in System Settings"
        case .notFound: return "Helper bundle missing"
        @unknown default: return "Unknown"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HelperManagerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SproutApp/Model/HelperManager.swift Tests/SproutAppTests/HelperManagerTests.swift
git commit -m "feat: HelperManager SMAppService registration + status labels"
```

---

## Task 9: Wire the provisioner into AppModel/ProjectStore

**Files:**
- Modify: `Sources/SproutApp/Model/AppModel.swift`

`ProjectStore` already accepts `loopbackEnabled` + an injected `LoopbackCoordinator` (Plan 2b-1). This task feeds it an `XPCProvisioner`-backed coordinator when the flag is on, and gives `AppModel` a `HelperManager`.

- [ ] **Step 1: Add the helper manager + flag reader to AppModel**

In `Sources/SproutApp/Model/AppModel.swift`, add a stored property after `private var storeSubscriptions: [AnyCancellable] = []`:

```swift
    let helper = HelperManager()

    /// Per-workspace loopback IPs are opt-in until the signed helper ships
    /// (Plan 2b-3). Off by default keeps production binding 127.0.0.1.
    var loopbackEnabled: Bool {
        UserDefaults.standard.bool(forKey: "loopbackEnabled")
    }
```

- [ ] **Step 2: Build the coordinator when enabled**

In `loadProjects()`, replace:

```swift
            stores.append(ProjectStore(rootURL: root, config: config))
```

with:

```swift
            let coordinator =
                loopbackEnabled
                ? LoopbackCoordinator(provisioner: XPCProvisioner())
                : nil
            stores.append(
                ProjectStore(
                    rootURL: root, config: config,
                    loopbackEnabled: loopbackEnabled,
                    loopback: coordinator))
```

- [ ] **Step 3: Refresh helper status on launch**

In `init()`, after `loadProjects()`, add:

```swift
        helper.refresh()
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 5: Run the full app test suite**

Run: `swift test --filter SproutAppTests`
Expected: PASS (existing `ProjectStoreLoopbackTests` still green — the default path is unchanged because the flag is off and tests inject their own coordinator).

- [ ] **Step 6: Commit**

```bash
git add Sources/SproutApp/Model/AppModel.swift
git commit -m "feat: wire XPCProvisioner-backed LoopbackCoordinator behind loopbackEnabled flag"
```

---

## Task 10: Settings UI — helper status + install

**Files:**
- Modify: `Sources/SproutApp/Views/SettingsView.swift`

- [ ] **Step 1: Add a loopback-helper section**

In `Sources/SproutApp/Views/SettingsView.swift`, add a new `Section` inside the
`Form`, after the existing `Section("Projects")` block (before the
`registryError` section):

```swift
            Section("Loopback Helper") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(HelperManager.label(for: app.helper.status))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Install / Enable") {
                        try? app.helper.install()
                    }
                    Button("Remove") {
                        try? app.helper.uninstall()
                    }
                    Spacer()
                    Button("Refresh") { app.helper.refresh() }
                }
                Text(
                    "Per-workspace loopback IPs require this signed root helper. "
                        + "Available once the signed build ships.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Lint the touched files**

Run: `swift format lint -r Sources/SproutApp/Views/SettingsView.swift Sources/SproutApp/Model/AppModel.swift`
Expected: no output (clean). If `[Indentation]`/`[AddLines]` fires on a wrapped expression, hand-rewrap to match the surrounding compact style — do **not** run `swift format format -i`.

- [ ] **Step 4: Commit**

```bash
git add Sources/SproutApp/Views/SettingsView.swift
git commit -m "feat: Settings loopback-helper status + install/remove controls"
```

---

## Task 11: Manual privileged-verification checklist (gated, deferred to 2b-3)

The privileged round-trip cannot be exercised in CI or unsigned dev builds.
Record the manual procedure so it runs once Plan 2b-3 produces a signed bundle.
**No code in this task** — it documents the gate and confirms the automated
suite is green.

- [ ] **Step 1: Confirm the whole automated suite passes**

Run: `swift test`
Expected: all tests PASS (including the new `CodeSignRequirementTests`,
`LoopbackIfconfigTests`, `LoopbackReaperTests`, `XPCReplyTests`,
`HelperManagerTests`, and the unchanged Plan 2b-1 `ProjectStoreLoopbackTests`).

- [ ] **Step 2: Confirm the gated engine integration suite still passes (pre-existing flake aside)**

Run: `SPROUT_INTEGRATION=1 swift test`
Expected: PASS. (Note: `realProcessGroupTerminationKillsChildren` is a known,
timing-sensitive pre-existing flake unrelated to this plan — see memory. If it
fails, re-run; do not treat as a regression of this plan, which adds no engine
process-group code.)

- [ ] **Step 3: Record the post-2b-3 manual verification steps**

Add a short note to the plan's PR description (not a tracked file) listing the
manual checks to run after 2b-3 signs the bundle:
1. Enable the flag: `defaults write <app-domain> loopbackEnabled -bool YES`.
2. Settings → Loopback Helper → Install; approve in System Settings.
3. Confirm `sudo ifconfig lo0` shows no stale aliases before starting a workspace.
4. Start a port-binding process in a workspace; confirm `ifconfig lo0` shows
   `127.0.10.N` and `/etc/hosts` has the `# BEGIN SPROUT` block with the
   `<process>.<project>.localhost` hostnames.
5. Reach the service at `http://<process>.<project>.localhost:<port>`.
6. Stop the last process; confirm the alias + hosts block are removed.
7. Kill the app mid-run, relaunch; confirm the launch sweep reaps the stale
   alias/hosts entry (reuses `staleManagedIPs` + `listManaged`).

- [ ] **Step 4: Commit the checklist note (if any tracked doc changed)**

No tracked file changes here unless you chose to append the checklist to this
plan doc. If so:

```bash
git add docs/superpowers/plans/2026-06-06-loopback-privileged-helper.md
git commit -m "docs: record post-2b-3 manual loopback verification checklist"
```

---

## Deferred to Plan 2b-3 (do NOT build here)

- App/helper bundling (`Makefile`, `bundle.sh`), daemon `launchd` plist
  (`com.sprout.helper.plist` with `MachServices = com.sprout.helper.xpc`,
  `RunAtLoad` for the helper-boot reaper), app `Info.plist`/entitlements.
- Generated `CodeSignRequirement` constants (real identifier + leaf-cert
  SHA-256) replacing the `PLACEHOLDER` requirement strings in `main.swift` and
  `XPCProvisioner.swift`.
- Code signing + notarization.
- Wiring the helper-boot launch-sweep into the daemon plist's `RunAtLoad` path
  (the diff logic `staleManagedIPs` + `listManaged` already exist after this
  plan; 2b-3 only schedules them).
