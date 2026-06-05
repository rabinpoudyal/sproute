# Loopback Helper Pure Logic (Plan 2a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and unit-test the privileged helper's pure decision logic — `/etc/hosts` managed-block editing and IP/hostname validation — with zero root, zero bundle, and zero runtime behavior change.

**Architecture:** Two new headless value-namespace files in `SproutEngine/Loopback/`. `SproutHostsBlock` transforms `/etc/hosts` *contents* (a `String`) by editing a single delimited managed block; it never touches the filesystem (the real helper in Plan 2b owns the atomic write). `LoopbackValidation` is a set of pure predicates plus a throwing wrapper that rejects out-of-range IPs and non-`localhost` hostnames before any side effect. Both are the exact functions the Plan 2b root helper will call, but here they are exercised entirely in `swift test`.

**Tech Stack:** Swift 6 (strict concurrency), Foundation only (no Swift Regex, no `NSRegularExpression` — manual parsing for determinism), Swift Testing (`import Testing`, `@Test`, `#expect`).

**Scope note:** This plan deliberately excludes `ProjectStore` refcount wiring, `IPAllocator` allocation-at-create, the XPC helper, and the bundling/signing pipeline. Those live in Plan 2b, where the real provisioner makes them non-inert and the manual integration checklist covers them. Reference design: `docs/superpowers/specs/2026-06-06-per-workspace-loopback-ips-design.md` (sections "Helper-side validation" and "/etc/hosts handling").

---

## File Structure

- **Create `Sources/SproutEngine/Loopback/SproutHostsBlock.swift`** — pure `/etc/hosts` managed-block editor. Public API: `managedIPs(contents:) -> [String]`, `upsert(contents:ip:hosts:) -> String`, `remove(contents:ip:) -> String`. Private `parse`/`render` round-trip helpers. Owns the `# BEGIN SPROUT` / `# END SPROUT` marker constants.
- **Create `Sources/SproutEngine/Loopback/LoopbackValidation.swift`** — pure validators. Public API: `isValidLoopbackIP(_:) -> Bool`, `isValidLoopbackHostname(_:) -> Bool`, `validateLoopbackRequest(ip:hosts:) throws`. Throws the existing `ProvisionError.helperRejected(String)` (defined in `LoopbackProvisioner.swift`) on the first failure.
- **Create `Tests/SproutEngineTests/SproutHostsBlockTests.swift`** — covers parse/upsert/remove/list with semantic assertions (presence of entries, marker presence/absence, preservation of foreign lines) rather than brittle whitespace matching.
- **Create `Tests/SproutEngineTests/LoopbackValidationTests.swift`** — covers IP range/format, hostname shape, and the throwing wrapper's accept/reject behavior.

These files import only `Foundation` and live in the existing `SproutEngine` target, so they run under the current `swift test` with no new target, no root, and no bundle.

---

## Task 1: SproutHostsBlock — parse + managedIPs

Establishes the file, the marker constants, the internal `parse`/`render` round-trip, and the read-only `managedIPs` accessor. `render` is written now (used by later tasks) and exercised indirectly through a parse→render round-trip test.

**Files:**
- Create: `Sources/SproutEngine/Loopback/SproutHostsBlock.swift`
- Test: `Tests/SproutEngineTests/SproutHostsBlockTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SproutEngineTests/SproutHostsBlockTests.swift`:

```swift
import Testing
@testable import SproutEngine

@Suite struct SproutHostsBlockTests {
    // A realistic /etc/hosts prefix that must always survive untouched.
    static let base = """
        ##
        # Host Database
        ##
        127.0.0.1\tlocalhost
        255.255.255.255\tbroadcasthost
        ::1\tlocalhost
        """

    static let withBlock = base + "\n" + """
        # BEGIN SPROUT (managed - do not edit)
        127.0.10.7 web.myproj.localhost vite.myproj.localhost
        127.0.10.8 web.other.localhost
        # END SPROUT
        """

    @Test func managedIPsEmptyWhenNoBlock() {
        #expect(SproutHostsBlock.managedIPs(contents: Self.base) == [])
    }

    @Test func managedIPsListsBlockIPsInOrder() {
        #expect(
            SproutHostsBlock.managedIPs(contents: Self.withBlock)
                == ["127.0.10.7", "127.0.10.8"])
    }

    @Test func foreignLinesSurviveAParseRenderRoundTrip() {
        // Removing an IP that isn't present is a no-op round-trip; user lines must persist.
        let out = SproutHostsBlock.remove(contents: Self.withBlock, ip: "127.0.10.99")
        #expect(out.contains("127.0.0.1\tlocalhost"))
        #expect(out.contains("::1\tlocalhost"))
        #expect(SproutHostsBlock.managedIPs(contents: out) == ["127.0.10.7", "127.0.10.8"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SproutHostsBlockTests`
Expected: FAIL — `cannot find 'SproutHostsBlock' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/SproutEngine/Loopback/SproutHostsBlock.swift`:

```swift
import Foundation

/// Pure editor for the single delimited block this tool manages inside an
/// `/etc/hosts`-shaped string. It never reads or writes the filesystem — the
/// privileged helper (Plan 2b) owns the atomic write. All user/foreign lines
/// outside the block are preserved verbatim across edits.
public enum SproutHostsBlock {
    static let begin = "# BEGIN SPROUT (managed - do not edit)"
    static let end = "# END SPROUT"

    /// One managed mapping: a loopback IP and the hostnames that resolve to it.
    struct Entry: Equatable {
        var ip: String
        var hosts: [String]
    }

    /// Split contents into the text before the block, the parsed entries, and
    /// the text after the block. When no well-formed block exists, everything is
    /// `head` and there are no entries (so a later render appends a fresh block).
    static func parse(_ contents: String) -> (head: String, entries: [Entry], tail: String) {
        let lines = contents.components(separatedBy: "\n")
        guard let b = lines.firstIndex(of: begin),
            let e = lines.firstIndex(of: end), e > b
        else {
            return (contents, [], "")
        }
        let head = lines[..<b].joined(separator: "\n")
        let tail = lines[(e + 1)...].joined(separator: "\n")
        var entries: [Entry] = []
        for line in lines[(b + 1)..<e] {
            let parts = line.split(separator: " ").map(String.init)
            guard let ip = parts.first else { continue }
            entries.append(Entry(ip: ip, hosts: Array(parts.dropFirst())))
        }
        return (head, entries, tail)
    }

    /// Reassemble contents. The block is emitted only when there are entries, so
    /// removing the last entry drops the markers entirely. Empty head/tail are
    /// skipped so we don't accumulate blank lines.
    static func render(head: String, entries: [Entry], tail: String) -> String {
        var sections: [String] = []
        if !head.isEmpty { sections.append(head) }
        if !entries.isEmpty {
            let block =
                [begin]
                + entries.map { "\($0.ip) \($0.hosts.joined(separator: " "))" }
                + [end]
            sections.append(block.joined(separator: "\n"))
        }
        if !tail.isEmpty { sections.append(tail) }
        return sections.joined(separator: "\n")
    }

    /// The loopback IPs currently present in the managed block, in file order.
    /// `[]` when there is no block. Used by the Plan 2b launch sweep.
    public static func managedIPs(contents: String) -> [String] {
        parse(contents).entries.map { $0.ip }
    }

    /// Remove the managed line for `ip` (no-op if absent). Drops the whole block
    /// when it becomes empty.
    public static func remove(contents: String, ip: String) -> String {
        let parsed = parse(contents)
        var entries = parsed.entries
        entries.removeAll { $0.ip == ip }
        return render(head: parsed.head, entries: entries, tail: parsed.tail)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SproutHostsBlockTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Lint**

Run: `swift format lint -r Sources/SproutEngine/Loopback Tests/SproutEngineTests/SproutHostsBlockTests.swift`
Expected: no output (clean).

- [ ] **Step 6: Commit**

```bash
git add Sources/SproutEngine/Loopback/SproutHostsBlock.swift Tests/SproutEngineTests/SproutHostsBlockTests.swift
git commit -m "feat: SproutHostsBlock parse/render + managedIPs/remove"
```

---

## Task 2: SproutHostsBlock — upsert

Adds `upsert`, which creates the block on first use, appends new IPs, replaces an existing IP's hostnames in place, is idempotent, and treats an empty `hosts` array as a removal.

**Files:**
- Modify: `Sources/SproutEngine/Loopback/SproutHostsBlock.swift`
- Test: `Tests/SproutEngineTests/SproutHostsBlockTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside `struct SproutHostsBlockTests` in `Tests/SproutEngineTests/SproutHostsBlockTests.swift`:

```swift
    @Test func upsertCreatesBlockAndPreservesUserLines() {
        let out = SproutHostsBlock.upsert(
            contents: Self.base, ip: "127.0.10.1", hosts: ["web.myproj.localhost"])
        #expect(out.contains(SproutHostsBlock.begin))
        #expect(out.contains(SproutHostsBlock.end))
        #expect(out.contains("127.0.10.1 web.myproj.localhost"))
        #expect(out.contains("127.0.0.1\tlocalhost"))  // user line untouched
        #expect(SproutHostsBlock.managedIPs(contents: out) == ["127.0.10.1"])
    }

    @Test func upsertAppendsSecondIP() {
        let one = SproutHostsBlock.upsert(
            contents: Self.base, ip: "127.0.10.1", hosts: ["web.a.localhost"])
        let two = SproutHostsBlock.upsert(
            contents: one, ip: "127.0.10.2", hosts: ["web.b.localhost"])
        #expect(SproutHostsBlock.managedIPs(contents: two) == ["127.0.10.1", "127.0.10.2"])
    }

    @Test func upsertReplacesHostsForExistingIP() {
        let one = SproutHostsBlock.upsert(
            contents: Self.base, ip: "127.0.10.1", hosts: ["old.a.localhost"])
        let two = SproutHostsBlock.upsert(
            contents: one, ip: "127.0.10.1", hosts: ["new.a.localhost", "vite.a.localhost"])
        #expect(two.contains("127.0.10.1 new.a.localhost vite.a.localhost"))
        #expect(!two.contains("old.a.localhost"))
        #expect(SproutHostsBlock.managedIPs(contents: two) == ["127.0.10.1"])
    }

    @Test func upsertIsIdempotent() {
        let one = SproutHostsBlock.upsert(
            contents: Self.base, ip: "127.0.10.1", hosts: ["web.a.localhost"])
        let two = SproutHostsBlock.upsert(
            contents: one, ip: "127.0.10.1", hosts: ["web.a.localhost"])
        #expect(one == two)
    }

    @Test func upsertWithEmptyHostsRemovesTheLine() {
        let one = SproutHostsBlock.upsert(
            contents: Self.base, ip: "127.0.10.1", hosts: ["web.a.localhost"])
        let gone = SproutHostsBlock.upsert(contents: one, ip: "127.0.10.1", hosts: [])
        #expect(SproutHostsBlock.managedIPs(contents: gone) == [])
        #expect(!gone.contains(SproutHostsBlock.begin))  // empty block dropped
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SproutHostsBlockTests`
Expected: FAIL — `type 'SproutHostsBlock' has no member 'upsert'`.

- [ ] **Step 3: Write the implementation**

Add this method to `enum SproutHostsBlock` in `Sources/SproutEngine/Loopback/SproutHostsBlock.swift`, immediately after `remove`:

```swift
    /// Insert or replace the managed line for `ip`. An empty `hosts` array is
    /// treated as a removal (so a caller clearing a workspace can pass `[]`).
    /// Idempotent: re-upserting the same ip+hosts yields identical contents.
    public static func upsert(contents: String, ip: String, hosts: [String]) -> String {
        if hosts.isEmpty { return remove(contents: contents, ip: ip) }
        let parsed = parse(contents)
        var entries = parsed.entries
        if let i = entries.firstIndex(where: { $0.ip == ip }) {
            entries[i].hosts = hosts
        } else {
            entries.append(Entry(ip: ip, hosts: hosts))
        }
        return render(head: parsed.head, entries: entries, tail: parsed.tail)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SproutHostsBlockTests`
Expected: PASS (8 tests total).

- [ ] **Step 5: Lint**

Run: `swift format lint -r Sources/SproutEngine/Loopback Tests/SproutEngineTests/SproutHostsBlockTests.swift`
Expected: no output (clean).

- [ ] **Step 6: Commit**

```bash
git add Sources/SproutEngine/Loopback/SproutHostsBlock.swift Tests/SproutEngineTests/SproutHostsBlockTests.swift
git commit -m "feat: SproutHostsBlock.upsert (create/replace/idempotent/empty-removes)"
```

---

## Task 3: SproutHostsBlock — remove edge cases

`remove` already exists from Task 1; this task pins its multi-entry and block-collapse behavior with explicit tests so a future refactor can't regress it.

**Files:**
- Test: `Tests/SproutEngineTests/SproutHostsBlockTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside `struct SproutHostsBlockTests`:

```swift
    @Test func removeOneOfManyKeepsOthers() {
        // Self.withBlock has 127.0.10.7 and 127.0.10.8.
        let out = SproutHostsBlock.remove(contents: Self.withBlock, ip: "127.0.10.7")
        #expect(SproutHostsBlock.managedIPs(contents: out) == ["127.0.10.8"])
        #expect(out.contains("127.0.10.8 web.other.localhost"))
        #expect(!out.contains("127.0.10.7"))
        #expect(out.contains(SproutHostsBlock.begin))  // block still present
    }

    @Test func removeLastDropsTheBlockEntirely() {
        let one = SproutHostsBlock.upsert(
            contents: Self.base, ip: "127.0.10.1", hosts: ["web.a.localhost"])
        let gone = SproutHostsBlock.remove(contents: one, ip: "127.0.10.1")
        #expect(!gone.contains(SproutHostsBlock.begin))
        #expect(!gone.contains(SproutHostsBlock.end))
        #expect(gone.contains("127.0.0.1\tlocalhost"))  // user content intact
    }
```

- [ ] **Step 2: Run tests to verify they fail**

These reference new test method names that don't exist yet, so the file won't compile against the old version only if you typo'd; the real signal is they must compile and PASS once added. Run:

Run: `swift test --filter SproutHostsBlockTests`
Expected: the two new tests are collected and PASS immediately (the behavior was implemented in Task 1's `remove`). If either fails, fix `remove`/`render` before continuing.

> Note: this task is pure test-hardening of already-shipped behavior, so there is no separate red→green implementation step. If both new tests pass on first run, that is the expected outcome.

- [ ] **Step 3: Lint**

Run: `swift format lint -r Tests/SproutEngineTests/SproutHostsBlockTests.swift`
Expected: no output (clean).

- [ ] **Step 4: Commit**

```bash
git add Tests/SproutEngineTests/SproutHostsBlockTests.swift
git commit -m "test: pin SproutHostsBlock.remove multi-entry and block-collapse cases"
```

---

## Task 4: LoopbackValidation — IP whitelist

Pure predicate that accepts exactly `127.0.10.N` with `N` in `1...254`, in canonical form (no leading zeros, no trailing junk).

**Files:**
- Create: `Sources/SproutEngine/Loopback/LoopbackValidation.swift`
- Test: `Tests/SproutEngineTests/LoopbackValidationTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/SproutEngineTests/LoopbackValidationTests.swift`:

```swift
import Testing
@testable import SproutEngine

@Suite struct LoopbackValidationTests {
    @Test func acceptsInRangeLoopbackIPs() {
        #expect(isValidLoopbackIP("127.0.10.1"))
        #expect(isValidLoopbackIP("127.0.10.42"))
        #expect(isValidLoopbackIP("127.0.10.254"))
    }

    @Test func rejectsOutOfRangeOctet() {
        #expect(!isValidLoopbackIP("127.0.10.0"))    // .0 network address
        #expect(!isValidLoopbackIP("127.0.10.255"))  // .255 broadcast
        #expect(!isValidLoopbackIP("127.0.10.256"))
    }

    @Test func rejectsWrongPrefix() {
        #expect(!isValidLoopbackIP("127.0.11.1"))
        #expect(!isValidLoopbackIP("127.0.0.1"))
        #expect(!isValidLoopbackIP("10.0.0.1"))
    }

    @Test func rejectsMalformed() {
        #expect(!isValidLoopbackIP("127.0.10.01"))   // non-canonical leading zero
        #expect(!isValidLoopbackIP("127.0.10.1 "))   // trailing space
        #expect(!isValidLoopbackIP("127.0.10."))
        #expect(!isValidLoopbackIP("127.0.10.1.5"))
        #expect(!isValidLoopbackIP(""))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LoopbackValidationTests`
Expected: FAIL — `cannot find 'isValidLoopbackIP' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/SproutEngine/Loopback/LoopbackValidation.swift`:

```swift
import Foundation

/// Whitelist validators the privileged helper (Plan 2b) runs on every request
/// before touching `lo0` or `/etc/hosts`. Kept here, in the headless engine, so
/// they are unit-tested without root. Manual parsing (no regex) keeps the rules
/// explicit and platform-independent.

/// True iff `ip` is exactly `127.0.10.N` with `N` in `1...254`, in canonical
/// decimal form. Rejects the network (.0) and broadcast (.255) addresses, any
/// other prefix, leading zeros, and trailing characters.
public func isValidLoopbackIP(_ ip: String) -> Bool {
    let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4,
        parts[0] == "127", parts[1] == "0", parts[2] == "10"
    else { return false }
    guard let n = Int(parts[3]), String(n) == parts[3], (1...254).contains(n) else {
        return false
    }
    return true
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LoopbackValidationTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Lint**

Run: `swift format lint -r Sources/SproutEngine/Loopback/LoopbackValidation.swift Tests/SproutEngineTests/LoopbackValidationTests.swift`
Expected: no output (clean).

- [ ] **Step 6: Commit**

```bash
git add Sources/SproutEngine/Loopback/LoopbackValidation.swift Tests/SproutEngineTests/LoopbackValidationTests.swift
git commit -m "feat: isValidLoopbackIP whitelist (127.0.10.1-254, canonical)"
```

---

## Task 5: LoopbackValidation — hostname whitelist

Pure predicate that accepts exactly `<label>.<label>.localhost` where each of the first two labels is non-empty and uses only `[a-z0-9-]`.

**Files:**
- Modify: `Sources/SproutEngine/Loopback/LoopbackValidation.swift`
- Test: `Tests/SproutEngineTests/LoopbackValidationTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside `struct LoopbackValidationTests`:

```swift
    @Test func acceptsProcessProjectLocalhost() {
        #expect(isValidLoopbackHostname("web.myproj.localhost"))
        #expect(isValidLoopbackHostname("vite.my-proj.localhost"))
        #expect(isValidLoopbackHostname("sidekiq-1.app2.localhost"))
    }

    @Test func rejectsBadHostnames() {
        #expect(!isValidLoopbackHostname("web.myproj.local"))     // wrong tld
        #expect(!isValidLoopbackHostname("web.localhost"))        // only 2 labels
        #expect(!isValidLoopbackHostname("a.b.c.localhost"))      // too many labels
        #expect(!isValidLoopbackHostname("WEB.myproj.localhost")) // uppercase
        #expect(!isValidLoopbackHostname(".myproj.localhost"))    // empty label
        #expect(!isValidLoopbackHostname("web.my_proj.localhost"))// underscore
        #expect(!isValidLoopbackHostname("web.myproj.localhost ")) // trailing space
        #expect(!isValidLoopbackHostname(""))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LoopbackValidationTests`
Expected: FAIL — `cannot find 'isValidLoopbackHostname' in scope`.

- [ ] **Step 3: Write the implementation**

Append to `Sources/SproutEngine/Loopback/LoopbackValidation.swift`:

```swift
/// True iff `host` is exactly `<label>.<label>.localhost`, where each of the two
/// leading labels is non-empty and composed only of lowercase letters, digits,
/// and hyphens. Mirrors `^[a-z0-9-]+\.[a-z0-9-]+\.localhost$`. Rejects anything
/// that could hijack a real domain in `/etc/hosts`.
public func isValidLoopbackHostname(_ host: String) -> Bool {
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count == 3, labels[2] == "localhost" else { return false }
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
    for label in labels.prefix(2) {
        guard !label.isEmpty, label.allSatisfy({ allowed.contains($0) }) else {
            return false
        }
    }
    return true
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LoopbackValidationTests`
Expected: PASS (6 tests total).

- [ ] **Step 5: Lint**

Run: `swift format lint -r Sources/SproutEngine/Loopback/LoopbackValidation.swift Tests/SproutEngineTests/LoopbackValidationTests.swift`
Expected: no output (clean).

- [ ] **Step 6: Commit**

```bash
git add Sources/SproutEngine/Loopback/LoopbackValidation.swift Tests/SproutEngineTests/LoopbackValidationTests.swift
git commit -m "feat: isValidLoopbackHostname whitelist (<proc>.<project>.localhost)"
```

---

## Task 6: LoopbackValidation — throwing request gate

A single entry point the helper calls per request: validate the IP and every hostname, throwing `ProvisionError.helperRejected(reason)` on the first failure. This is the function Plan 2b's `HelperService.setActive` calls before any side effect.

**Files:**
- Modify: `Sources/SproutEngine/Loopback/LoopbackValidation.swift`
- Test: `Tests/SproutEngineTests/LoopbackValidationTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside `struct LoopbackValidationTests`:

```swift
    @Test func gateAcceptsValidRequest() throws {
        try validateLoopbackRequest(
            ip: "127.0.10.5",
            hosts: ["web.myproj.localhost", "vite.myproj.localhost"])
    }

    @Test func gateRejectsBadIP() {
        #expect(throws: ProvisionError.helperRejected("invalid ip: 10.0.0.1")) {
            try validateLoopbackRequest(ip: "10.0.0.1", hosts: ["web.myproj.localhost"])
        }
    }

    @Test func gateRejectsBadHostname() {
        #expect(throws: ProvisionError.helperRejected("invalid hostname: evil.com")) {
            try validateLoopbackRequest(ip: "127.0.10.5", hosts: ["evil.com"])
        }
    }

    @Test func gateAcceptsEmptyHosts() throws {
        // Deactivation passes [] hostnames; the IP must still be in range.
        try validateLoopbackRequest(ip: "127.0.10.5", hosts: [])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LoopbackValidationTests`
Expected: FAIL — `cannot find 'validateLoopbackRequest' in scope`.

- [ ] **Step 3: Write the implementation**

Append to `Sources/SproutEngine/Loopback/LoopbackValidation.swift`:

```swift
/// The single validation gate the privileged helper runs before any side
/// effect. Throws `ProvisionError.helperRejected` with a human-readable reason
/// on the first invalid input. Empty `hosts` is allowed (a deactivation), but
/// the IP is always range-checked.
public func validateLoopbackRequest(ip: String, hosts: [String]) throws {
    guard isValidLoopbackIP(ip) else {
        throw ProvisionError.helperRejected("invalid ip: \(ip)")
    }
    for host in hosts where !isValidLoopbackHostname(host) {
        throw ProvisionError.helperRejected("invalid hostname: \(host)")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LoopbackValidationTests`
Expected: PASS (10 tests total).

- [ ] **Step 5: Full suite + lint**

Run: `swift test`
Expected: PASS — full suite green (Plan 1's 105 tests plus the new SproutHostsBlock/LoopbackValidation tests).

Run: `swift format lint -r Sources Tests`
Expected: no output (clean).

- [ ] **Step 6: Commit**

```bash
git add Sources/SproutEngine/Loopback/LoopbackValidation.swift Tests/SproutEngineTests/LoopbackValidationTests.swift
git commit -m "feat: validateLoopbackRequest gate throwing helperRejected"
```

---

## Done criteria

- `SproutHostsBlock` and `LoopbackValidation` exist in `Sources/SproutEngine/Loopback/`, Foundation-only, warning-free.
- `swift test` is fully green; `swift format lint -r Sources Tests` is clean.
- No runtime behavior change: nothing calls these yet (the wiring is Plan 2b). `bindIP` still defaults to `127.0.0.1`; the prod provisioner is still `Noop`.
- Plan 2b can call `validateLoopbackRequest` and `SproutHostsBlock.upsert/remove/managedIPs` verbatim from the root helper.
