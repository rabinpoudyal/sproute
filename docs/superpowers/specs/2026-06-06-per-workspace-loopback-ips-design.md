# Per-Workspace Loopback IPs

Date: 2026-06-06
Status: Approved (design), pending implementation plan

## Problem

Sprout runs each branch's dev servers as native macOS processes. Today every
port-binding process gets a fixed, deterministic port (`web` 3000, `vite` 5173),
and the design assumes **one active workspace per project at a time** so those
ports never collide. We want the opposite: run **many branches concurrently**,
each with the *same internal ports*, the way Docker containers each get their own
network namespace.

Docker achieves this on Linux via per-container network namespaces (separate
`localhost` each) plus veth/bridge/iptables NAT. None of that exists natively on
macOS — Docker/Podman on a Mac actually run a hidden Linux VM. The user is
building a *native* runner and does not want a VM.

The macOS-native way to get the same effect without a VM: give each workspace its
own **loopback IP**. A socket is identified by `IP:port`, so `127.0.10.1:3000` and
`127.0.10.2:3000` do not collide. Each branch binds the same internal ports on a
distinct `127.0.10.N`.

The catch: unlike Linux (whole `127.0.0.0/8` bound to `lo` by default), macOS only
configures `127.0.0.1` on `lo0`. Binding `127.0.10.1` fails with `EADDRNOTAVAIL`
until an alias is added (`ifconfig lo0 alias 127.0.10.1 up`), which requires root.

## Goals

1. Run multiple branches of a project simultaneously, each on its own
   `127.0.10.N`, all reusing the same internal ports.
2. Reach each running branch in the browser via per-process hostnames
   `<process>.<project>.localhost:<port>` (e.g. `web.myproj.localhost:3000`).
3. Do the privileged loopback-alias and `/etc/hosts` work through a properly
   scoped, validated root helper — never give the GUI app root.

## Non-goals

- Cross-project IP coordination beyond a single global allocator. (The allocator
  *is* global across projects, but there is no other coordination.)
- Concurrency for the CLI (`sprout-cli`). Per-IP is an **app-only** feature; the
  CLI keeps single-IP `127.0.0.1` behavior. The CLI cannot register an
  SMAppService daemon (it is not a bundled app).
- A reverse proxy. Access is `hostname:port`, not bare `hostname` on `:80`.
- Notarization / Developer ID distribution. Local-only, self-signed.
- Reaping orphaned processes that hold a fixed port from a prior crashed session
  beyond the alias/hosts sweep described below.

## Decisions locked during brainstorming

- **Signing reality:** self-signed, local-only. App + helper signed with one
  locally-generated cert; the helper's client requirement is pinned to that
  cert's SHA-256 hash.
- **Goal:** run many branches at once (not merely stable ports). The
  single-active rule is not introduced (it was specced earlier but never
  implemented — `stopOthers` does not exist in the code).
- **Access:** hostnames **with** port — `web.myproj.localhost:3000`. The helper
  manages both `lo0` aliases and an `/etc/hosts` managed block. No proxy.
- **IP allocation:** one global, persisted, sequential allocator in `~/.sprout`,
  reusing freed IPs. Hostnames namespaced by project to avoid cross-project
  clashes.
- **Lifetime:** provision IP + hosts **on process start, release when all of a
  workspace's processes stop** (reference-counted). Hostnames vanish when a
  workspace is fully stopped.
- **Helper realization:** SMAppService daemon + XPC (Approach 1). Requires a new
  `.app` bundle + self-signed signing pipeline (prerequisite work).
- **Cert requirement:** pinned-hash (strongest; user controls the cert).
- **Hostname scheme:** per-process hostnames, all resolving to the one workspace
  IP, differing only by port.

## Architecture

Three layers with clean boundaries:

```
SproutApp (.app bundle, self-signed)
  ProjectStore
    -> IPAllocator           (global registry, ~/.sprout/loopback.json)
    -> LoopbackProvisioner    (protocol; engine seam)
         └─ XPCProvisioner    -> NSXPCConnection -> mach service
                              │ XPC (mutually validated)
com.sprout.helper (root LaunchDaemon, embedded in bundle)
  HelperService : NSXPCListenerDelegate
    setActive(ip, hostnames, active:) ->
       /sbin/ifconfig lo0 alias/-alias
       rewrite /etc/hosts managed block
    validates: peer code-signature + IP in 127.0.10.0/24 + hostname regex
```

### Components

| Component | Layer | Responsibility |
|---|---|---|
| `IPAllocator` | SproutEngine | Persisted `(project,branch) -> 127.0.10.N` map. Sequential lowest-free alloc, reuse freed. Pure logic over an injected `FileSystem`. |
| `LoopbackProvisioner` (protocol) | SproutEngine | Seam: `setActive(_ ip:, hosts:, active:) async throws`. Tests inject a fake; engine stays headless and root-free. |
| `XPCProvisioner` | SproutApp | Concrete `LoopbackProvisioner`. Opens a validated XPC connection to the helper and forwards the request. |
| `com.sprout.helper` | new executable target | Root daemon. The only code that touches `ifconfig` / `/etc/hosts`. |

### Boundaries / rationale

- The engine never touches root or XPC — it knows only `LoopbackProvisioner` +
  `IPAllocator`, keeping it testable and headless.
- The helper performs exactly two narrow operations (alias, hosts line); no shell
  passthrough, no general exec — minimal attack surface.
- `ProjectStore` orchestrates: allocate IP at create -> on first process start,
  call the provisioner -> thread `{{host}}` / `bindIP` through the existing
  `context()` / `childEnv()` choke point (ProjectStore.swift lines 116-129).

## Engine seam

### IPAllocator (new, SproutEngine)

```swift
public struct LoopbackAllocation: Codable, Sendable, Equatable {
    public var project: String
    public var branch: String
    public var ip: String          // "127.0.10.7"
}

public actor IPAllocator {
    // persists ~/.sprout/loopback.json via an injected FileSystem
    public func allocate(project: String, branch: String) throws -> String
    public func release(project: String, branch: String) throws
    public func ip(project: String, branch: String) -> String?
}
```

- Range `127.0.10.1 ... 127.0.10.254`. Sequential lowest-free, reuse released
  slots. Past 254 -> `LoopbackError.exhausted`.
- `allocate` is idempotent: an existing `(project,branch)` returns its current IP.
- Persistence mirrors `JSONStateStore` (injected `FileSystem`, atomic write).

### WorkspaceRecord migration

Add `public var bindIP: String`. The custom `init(from:)` (StateStore.swift line
39) uses `decodeIfPresent(...) ?? "127.0.0.1"`, so old records default to
loopback. No migration tool. `bindIP` is set at create-time from the allocator and
is stable for the workspace's life.

### TemplateContext + renderer

Add `public var host: String` (default `"127.0.0.1"`). The renderer adds
`"{{host}}"` -> `ctx.host`. `.sprout.toml` commands bind the host:

```toml
[[run.process]]
name = "web"
command = "bin/rails server -b {{host}} -p {{port}}"
port = 3000

[[run.process]]
name = "vite"
# --strictPort prevents drift; bind to the instance IP
command = "bin/vite dev --host {{host}} --port {{port}} --strictPort"
port = 5173
```

The same port is used by every workspace now; the IP disambiguates.
Cross-references still resolve: `VITE_URL=http://{{host}}:{{port.vite}}`.

### ProjectStore threading (lines 116-129)

```swift
private func context(_ rec, process name) -> TemplateContext {
    // + host: rec.bindIP
}
private func childEnv(_ rec, process name) -> [String:String] {
    // + "HOST": rec.bindIP, "BIND_IP": rec.bindIP
    // DATABASE_URL unchanged — Postgres stays on 127.0.0.1, reachable from the alias IP
}
```

One change in each function; everything downstream (processes, consoles, drawer
shell, create-time launch) inherits it.

### Correctness contract

Every port-binding process **must** bind `{{host}}`, never `0.0.0.0`. A `0.0.0.0`
bind claims the port on *all* loopback IPs, re-introducing collisions. This is a
configuration/documentation contract (not enforceable in code) — flag it in docs
and the sample `.sprout.toml`.

Database isolation is unchanged: per-branch `dbName` already exists; Postgres
stays on `127.0.0.1` and is reachable from any alias IP because the host owns all
its loopback addresses.

## Privileged helper, XPC, and security

### Helper target

New executable target `com.sprout.helper`, embedded at
`Sprout.app/Contents/MacOS/com.sprout.helper`, registered via
`SMAppService.daemon(plistName: "com.sprout.helper.plist")`. The bundled launchd
plist (`Contents/Library/LaunchDaemons/`) declares a `MachServices` entry
`com.sprout.helper.xpc`.

### XPC protocol (deliberately narrow)

```swift
@objc public protocol HelperProtocol {
    // The ONLY privileged operation. The helper builds every command itself.
    func setActive(ip: String,
                   hostnames: [String],
                   active: Bool,
                   reply: @escaping (Bool, String?) -> Void)
    func ping(reply: @escaping (String) -> Void)        // version / health
    func listManaged(reply: @escaping ([String]) -> Void)  // current managed IPs (for sweep)
}
```

No method accepts a command, path, or shell string. The helper constructs
`ifconfig lo0 alias <ip> up` / `ifconfig lo0 -alias <ip>` and the `/etc/hosts`
block from validated primitives. There is no general-exec surface.

### Helper-side validation (every request, before any side effect)

1. **Caller code-signature.** From the XPC connection's `auditToken`, build a
   `SecCode` and verify it against a requirement pinned to our self-signed cert:
   `identifier "com.sprout.app" and certificate leaf = H"<sha256-of-cert>"`.
   Reject mismatches. Stops any other local process from driving the root helper.
2. **IP whitelist.** `ip` must match `^127\.0\.10\.(\d{1,3})$` with the final
   octet in `1...254`. Rejects aliasing arbitrary addresses (e.g. a real LAN IP).
3. **Hostname whitelist.** Each entry must match
   `^[a-z0-9-]+\.[a-z0-9-]+\.localhost$` (`<process>.<project>.localhost`).
   Rejects hijacking real domains in `/etc/hosts`.

Any validation failure -> `reply(false, "reason")`, no side effect.

### /etc/hosts handling

The helper owns a single delimited block and never edits user lines:

```
# BEGIN SPROUT (managed - do not edit)
127.0.10.7 web.myproj.localhost vite.myproj.localhost
# END SPROUT
```

`setActive(active: true)` upserts the IP's line within the block;
`active: false` removes that one line. The block is rewritten atomically
(temp file + rename). It is created on the first line and removed entirely when
empty.

### ifconfig handling

- `active: true` -> `/sbin/ifconfig lo0 alias <ip> up` (idempotent — re-aliasing
  an existing alias is a no-op success).
- `active: false` -> `/sbin/ifconfig lo0 -alias <ip>`.

The helper invokes `Process` with an **absolute path** and a fixed argument array,
never `/bin/sh -c` and never string interpolation into a shell.

### Mutual trust

The app also pins its XPC connection to the helper's identity
(`setCodeSigningRequirement`), so a rogue daemon cannot impersonate the mach
service. Both directions are pinned to the same self-signed cert.

## Bundling + signing pipeline (prerequisite)

SMAppService requires a real signed `.app`. None exists today (pure SwiftPM). A
new build path is added, kept out of `swift build` so the dev loop stays fast.

### Bundle layout

```
Sprout.app/
  Contents/
    Info.plist                       (CFBundleIdentifier com.sprout.app, LSUIElement, etc.)
    MacOS/SproutApp                  (swift build product, copied in)
    MacOS/com.sprout.helper          (new executable target, copied in)
    Library/LaunchDaemons/
      com.sprout.helper.plist        (Label, BundleProgram, MachServices=com.sprout.helper.xpc)
```

### Build script (`scripts/bundle.sh`, invoked via `make app`)

1. `swift build -c release` -> both executables.
2. Assemble the `Sprout.app` tree, copy binaries, write the two plists.
3. **Sign inside-out** with the local self-signed cert (`codesign`,
   hardened-runtime): sign `com.sprout.helper`, then `SproutApp`, then the outer
   `.app`. Both binaries share one signing identity, so the pinned-hash
   requirement resolves on both sides.
4. Print the cert's SHA-256 for the pinned requirement.

### Cert + pinned-hash bootstrap (chicken/egg)

The pinned requirement embeds the cert hash, which only exists after the cert is
made. Resolve once:

1. `make certs` -> create the self-signed "Sprout Dev" cert in the login keychain;
   print SHA-256; write it into a generated `CodeSignRequirement.swift` constant
   and the helper plist template.
2. `make app` -> `bundle.sh` signs with that cert; the hash matches.

Re-run `make certs` only when regenerating the cert.

### Install / register

- On first launch (or a menu action), the app calls
  `SMAppService.daemon(plistName:).register()`, triggering the single admin auth
  prompt (Touch ID / password). Status is surfaced in the UI; `.requiresApproval`
  deep-links to System Settings > Login Items.
- Uninstall: `.unregister()`, and the helper removes its hosts block + aliases on
  teardown.

### Dev ergonomics

- `swift build` / `swift test` are unchanged — engine and logic remain testable
  without the bundle.
- The bundle is only needed to exercise the real privileged path. Unit tests use
  a fake `LoopbackProvisioner`; the bundling/signing path is verified via a
  documented manual checklist (an unsigned CI box cannot register the daemon).

### New tooling

A `Makefile` is introduced (the repo has none): `make certs`, `make app`,
`make install`.

## Lifecycle, refcounting, crash recovery

"Only while running": the IP + hosts entry exists while at least one of a
workspace's processes runs. Multiple processes per workspace -> reference-count;
provision on the first, release on the last.

### Refcount in ProjectStore

```swift
private var activeProcessCount: [String: Int] = [:]   // branch -> running count
```

The IP itself is allocated at **create** (`IPAllocator.allocate`, stored in
`rec.bindIP`); the alias + hosts are installed only while running.

### Flow

```
startProcess(branch, name):
  count = activeProcessCount[branch] ?? 0
  if count == 0:
      hosts = perProcessHostnames(branch)   # web.proj.localhost, vite.proj.localhost, ...
      try await provisioner.setActive(rec.bindIP, hosts, active: true)
  activeProcessCount[branch] = count + 1
  ... existing supervisor.start ...

on process stop OR exit (handleProcessExit / stopProcess):
  activeProcessCount[branch] -= 1
  if reaches 0:
      try? await provisioner.setActive(rec.bindIP, hosts, active: false)
```

`setActive(true)` is idempotent in the helper, so a double-call/race is safe.
Hostnames are computed from `config.run.processes` (all binders) so a workspace's
hosts go up together on first start.

### Failure handling

- **Provision fails on first start** (helper down, unregistered, validation
  reject): surface `AppError`, **abort the start** (do not launch a server bound
  to an unreachable IP). Refcount not incremented.
- **Release fails on last stop:** log, do not block the stop. Stale state is
  reaped by the sweep below.

### Crash recovery / stale cleanup

Aliases + hosts are host-global and outlive a crashed app. Two reapers:

1. **App-launch sweep.** On `ProjectStore` init / app start, `listManaged()`
   returns the helper's current managed IPs (its `/etc/hosts` block + `lo0`
   aliases in range). The app diffs against actually-running workspaces (none at
   fresh launch) and tells the helper to clear stale entries — effectively a clean
   slate each launch, since nothing is running yet.
2. **Helper boot.** The LaunchDaemon `RunAtLoad` clears any leftover SPROUT hosts
   block + range aliases on reboot. Prevents accumulation across reboots.

### Teardown

`teardown()` already stops processes (refcount -> 0 -> release fires naturally).
Belt-and-suspenders: an explicit `setActive(false)` + `IPAllocator.release` so the
IP returns to the pool. Hosts line + alias gone.

### CLI

Unaffected — the CLI path does not refcount or provision (single-IP `127.0.0.1`,
app-only feature per Architecture).

## Error handling

```swift
public enum LoopbackError: Error, Equatable {
    case exhausted                    // > 254 IPs allocated
    case notAllocated(branch: String)
    case persistFailed(String)
}

public enum ProvisionError: Error, Equatable {
    case helperUnavailable            // daemon not registered / XPC connect failed
    case helperRejected(String)       // validation failure reason from helper
    case ifconfigFailed(String)
    case hostsWriteFailed(String)
}
```

The app maps both to `AppError` (existing convention) for user-facing text.
`ProvisionError.helperUnavailable` produces an actionable message with a
deep-link to register the daemon.

## Testing

### Unit (no root, no bundle — current `swift test`)

| Target | Tests |
|---|---|
| `IPAllocatorTests` | sequential alloc; reuse freed slot; idempotent same (project,branch); exhaustion throws; persistence round-trip via a fake `FileSystem`. |
| `TemplateRendererTests` | `{{host}}` renders; default `127.0.0.1`; coexists with `{{port}}` / `{{port.x}}`. |
| `WorkspaceRecordTests` | decode old JSON without `bindIP` -> `127.0.0.1`; encode/decode round-trip. |
| `ProjectStoreTests` | refcount: first start provisions once, last stop releases once; multi-process start provisions one time; provision-fail aborts start. Uses a fake `LoopbackProvisioner` that records calls. |
| Helper validation logic | IP regex, hostname regex, and hosts-block rewrite are pure functions in a testable module — unit-test accept/reject cases and block upsert/remove/empty without touching real `/etc/hosts`. |

### Gated integration (`SPROUT_INTEGRATION=1`)

- Real `ifconfig` alias add/remove on `127.0.10.250` (high slot), assert
  reachable, then clean up. Requires the signed helper present, so in practice it
  is a manual-checklist item rather than CI (an unsigned CI box cannot register
  the daemon).

### Manual verification checklist

1. `make certs && make app` -> `Sprout.app` signed.
2. Launch -> register daemon -> admin prompt -> status "enabled".
3. Create 2 branches, start both -> `ifconfig lo0` shows 2 aliases; `/etc/hosts`
   shows the SPROUT block with per-process hosts.
4. Both rails reachable at their `*.localhost:port` simultaneously.
5. Stop one -> its alias + hosts line gone, the other intact.
6. Force-quit the app, relaunch -> sweep clears stale entries.

### Testability principle

The helper's privileged *effects* are thin; all *decisions* (validation, block
rewrite, IP math) are pure functions tested without root. The irreducible root
part (actual `ifconfig` / hosts write) is the only manual surface.

## Open risks

- A self-signed cert regeneration changes the pinned hash, breaking the helper's
  client requirement until `make certs` regenerates the embedded constant + plist
  and the app/helper are re-signed. Acceptable for a stable local cert made once.
- An orphaned process from a prior crash could still hold a fixed port on a
  specific alias IP when that workspace next starts; this affects only that one
  workspace, not others. Reaping such untracked orphans is out of scope beyond the
  alias/hosts sweep.
- `/etc/hosts` is shared system state; the managed-block approach avoids touching
  user lines, but a user manually editing inside the SPROUT block would be
  overwritten on the next rewrite.
