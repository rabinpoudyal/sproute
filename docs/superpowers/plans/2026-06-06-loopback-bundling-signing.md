# Loopback Bundling + Signing Pipeline (Plan 2b-3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a signed `Sprout.app` bundle (app + root helper + LaunchDaemon plist) with a self-signed local cert, and wire the generated leaf-cert hash into the code-signature pins that currently hold `PLACEHOLDER` literals, so the privileged loopback helper can actually be registered and trusted.

**Architecture:** A `make`-driven build path kept entirely out of `swift build`/`swift test` (dev loop stays fast). `make certs` mints a self-signed "Sprout Dev" code-signing cert in the login keychain and regenerates a checked-in Swift constant holding the leaf SHA-256. `make app` runs `scripts/bundle.sh`: release build → assemble the `.app` tree → write `Info.plist` + the LaunchDaemon plist → sign inside-out (helper, app binary, outer `.app`) with that one identity. Both pin directions resolve against the same leaf hash. A helper boot sweep (`RunAtLoad`) clears stale aliases/hosts after a crash or reboot.

**Tech Stack:** Swift 6 (SwiftPM), `codesign`, `openssl`/`security` (self-signed cert), `SMAppService` LaunchDaemon plist, GNU make, bash. macOS 14+.

---

## Context for the implementer

You have **not** seen this codebase. Key facts you need:

- This is **Sprout**, a Swift Package with three products: `SproutEngine` (library), `sprout` (CLI), `SproutApp` (SwiftUI app), plus a new `sprout-helper` executable target (`Sources/SproutHelper/`) and a C shim target `CSproutXPC`.
- The loopback feature (per-workspace `127.0.10.N` IPs) is **off by default** (`UserDefaults` key `loopbackEnabled`, default false). Nothing here turns it on; this plan only builds the signing/bundling path it depends on.
- Plan 2b-2 (already merged) built the privileged helper end-to-end but left two **placeholder code-signing requirement strings** that never match a real signature, so the helper fails closed on every call. This plan replaces them with a real generated leaf-cert hash.
- **Build/lint discipline (enforced by a pre-commit hook):** `swift format lint -r Sources Tests` (strict), then `swift build`, then `swift test` must all pass. Never use `--no-verify` or `git commit --amend`. Style: 4-space indent, ~100 col soft limit. Do **not** run `swift format format -i` (it rewraps the intentional compact style).
- **Swift Testing**, not XCTest: `import Testing`, `@Suite`, `@Test`, `#expect`. Note: `#expect` cannot take a multi-line expression cleanly under the strict formatter — bind the expected value to a `let` first, then `#expect(actual == expected)`.
- Comments explain **why**, not what. Don't add docstrings to unchanged code.
- Most of this plan is shell/plist/Makefile, which is **not unit-testable** and cannot run on an unsigned CI box. Those tasks end with a **manual verification checklist** instead of an automated test. The few Swift edits (Tasks 1–2) do get tests.

### Current placeholder sites (verbatim — you will replace these)

`Sources/SproutHelper/main.swift:8`:
```swift
let appRequirement = "identifier \"com.sprout.app.PLACEHOLDER\""
```
This is passed to `HelperService(appRequirement:)`, which uses it to decide whether a *connecting caller* (the app) is allowed. So the helper pins the **app** identity.

`Sources/SproutApp/Model/XPCProvisioner.swift:15`:
```swift
private let helperRequirement = "identifier \"com.sprout.helper.PLACEHOLDER\""
```
This is passed to `conn.setCodeSigningRequirement(...)`, so the app pins the **helper** identity.

Both targets `import SproutEngine`, so a shared constant living in `SproutEngine` is visible to both.

### Existing primitive you will wire (do not reimplement)

`Sources/SproutEngine/Loopback/CodeSignRequirement.swift`:
```swift
public func codeSigningRequirement(
    identifier: String, leafCertSHA256Hex: String
) -> String {
    "identifier \"\(identifier)\" and certificate leaf = H\"\(leafCertSHA256Hex)\""
}
```

### File structure this plan creates / modifies

- Create: `Sources/SproutEngine/Loopback/SigningConstants.swift` — checked-in constant (placeholder hash by default; `make certs` rewrites the hash line). Exposes `SproutSigning.appRequirement` / `.helperRequirement`.
- Modify: `Sources/SproutHelper/main.swift` — use `SproutSigning.appRequirement`; add boot sweep.
- Modify: `Sources/SproutApp/Model/XPCProvisioner.swift` — use `SproutSigning.helperRequirement`.
- Modify: `Sources/SproutHelper/PrivilegedEffects.swift` — add `clearAllManaged()` boot reaper.
- Create: `packaging/Info.plist` — app bundle Info.plist.
- Create: `packaging/com.sprout.helper.plist` — LaunchDaemon plist.
- Create: `scripts/gen-cert.sh` — self-signed cert + regenerate `SigningConstants.swift`.
- Create: `scripts/bundle.sh` — assemble + sign the `.app`.
- Create: `Makefile` — `certs`, `app`, `install`, `clean`.
- Modify: `.gitignore` — ignore `build/`.
- Create: `docs/MANUAL-VERIFICATION-2b-3.md` — signed-path checklist.

---

### Task 1: Generated signing constant + wire both pins

**Files:**
- Create: `Sources/SproutEngine/Loopback/SigningConstants.swift`
- Modify: `Sources/SproutHelper/main.swift:8`
- Modify: `Sources/SproutApp/Model/XPCProvisioner.swift:15`
- Test: `Tests/SproutEngineTests/SigningConstantsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SproutEngineTests/SigningConstantsTests.swift`:

```swift
import Testing

@testable import SproutEngine

@Suite struct SigningConstantsTests {
    @Test func appRequirementComposesIdentifierAndLeafHash() {
        let expected = codeSigningRequirement(
            identifier: SproutSigning.appIdentifier,
            leafCertSHA256Hex: SproutSigning.leafCertSHA256Hex)
        #expect(SproutSigning.appRequirement == expected)
    }

    @Test func helperRequirementComposesIdentifierAndLeafHash() {
        let expected = codeSigningRequirement(
            identifier: SproutSigning.helperIdentifier,
            leafCertSHA256Hex: SproutSigning.leafCertSHA256Hex)
        #expect(SproutSigning.helperRequirement == expected)
    }

    @Test func identifiersAreStable() {
        #expect(SproutSigning.appIdentifier == "com.sprout.app")
        #expect(SproutSigning.helperIdentifier == "com.sprout.helper")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SigningConstantsTests`
Expected: FAIL — `cannot find 'SproutSigning' in scope` (file not created yet).

- [ ] **Step 3: Create the constant**

Create `Sources/SproutEngine/Loopback/SigningConstants.swift`:

```swift
import Foundation

/// Self-signed code-signing identity the app and helper pin each other against.
///
/// The `leafCertSHA256Hex` below is a placeholder that never matches a real
/// signature, so an unsigned dev build fails closed — the helper rejects every
/// caller and the app refuses to talk to any helper. `make certs` rewrites the
/// hash line with the real "Sprout Dev" leaf hash after minting the cert.
///
/// NOTE: do not commit a regenerated hash. It is local to whoever ran
/// `make certs`; the placeholder is what belongs in version control.
public enum SproutSigning {
    public static let appIdentifier = "com.sprout.app"
    public static let helperIdentifier = "com.sprout.helper"

    /// SHA-256 (uppercase hex) of the signing cert leaf, in the form the
    /// requirement language's `H"..."` literal expects. Rewritten by
    /// `make certs`.
    public static let leafCertSHA256Hex =
        "0000000000000000000000000000000000000000000000000000000000000000"

    /// Requirement the helper applies to *callers* (must be the app).
    public static var appRequirement: String {
        codeSigningRequirement(
            identifier: appIdentifier, leafCertSHA256Hex: leafCertSHA256Hex)
    }

    /// Requirement the app applies to the *helper* connection.
    public static var helperRequirement: String {
        codeSigningRequirement(
            identifier: helperIdentifier, leafCertSHA256Hex: leafCertSHA256Hex)
    }
}
```

- [ ] **Step 4: Wire the helper pin**

In `Sources/SproutHelper/main.swift`, replace the placeholder block (the comment lines 4–8 and the literal) so it reads:

```swift
import Foundation
import SproutEngine

// The app and helper pin each other against the self-signed "Sprout Dev" leaf
// (see SproutSigning). Unsigned dev builds fail closed: the placeholder hash
// rejects all callers until `make certs` + `make app` produce a real signature.
let appRequirement = SproutSigning.appRequirement

let delegate = HelperService(appRequirement: appRequirement)
let listener = NSXPCListener(machServiceName: sproutHelperMachServiceName)
listener.delegate = delegate
listener.resume()

// launchd owns the lifetime; park the main thread.
RunLoop.current.run()
```

(Task 2 inserts the boot sweep here; leave room above `listener.resume()`.)

- [ ] **Step 5: Wire the app pin**

In `Sources/SproutApp/Model/XPCProvisioner.swift`, replace lines 12–15 (the placeholder doc comment + literal) with:

```swift
    /// The app pins the helper against the self-signed "Sprout Dev" leaf
    /// (see `SproutSigning`). A swapped-out helper binary fails the check.
    private let helperRequirement = SproutSigning.helperRequirement
```

- [ ] **Step 6: Run tests + build to verify they pass**

Run: `swift test --filter SigningConstantsTests`
Expected: PASS (3 tests).
Run: `swift build`
Expected: builds clean, no warnings.

- [ ] **Step 7: Commit**

```bash
git add Sources/SproutEngine/Loopback/SigningConstants.swift \
        Sources/SproutHelper/main.swift \
        Sources/SproutApp/Model/XPCProvisioner.swift \
        Tests/SproutEngineTests/SigningConstantsTests.swift
git commit -m "feat: pin app/helper to generated SproutSigning leaf hash"
```

---

### Task 2: Helper boot sweep (RunAtLoad reaper)

**Files:**
- Modify: `Sources/SproutHelper/PrivilegedEffects.swift`
- Modify: `Sources/SproutHelper/main.swift`

Rationale: `lo0` aliases and the `/etc/hosts` SPROUT block are host-global and survive a crashed app. The LaunchDaemon has `RunAtLoad` (Task 4), so the helper starts at boot; on startup it should drop every managed IP (nothing is running yet, so a clean slate is correct). Reuses the already-validated `apply(active: false)` path per IP.

There is no automated test: `PrivilegedEffects` mutates the real `/etc/hosts` and runs `/sbin/ifconfig`, which require root and are not unit-testable. Verification is manual (Task 8 checklist).

- [ ] **Step 1: Add the sweep to PrivilegedEffects**

In `Sources/SproutHelper/PrivilegedEffects.swift`, add this method inside the `enum PrivilegedEffects` body, right after `managedIPs()`:

```swift
    /// Boot/launch sweep: drop every currently-managed IP (its hosts entry and
    /// `lo0` alias). Run at helper startup (`RunAtLoad`) so a crash or reboot
    /// can't leave stale aliases behind. Best-effort — a failure on one IP must
    /// not abort the rest, so per-IP errors are swallowed.
    static func clearAllManaged() {
        for ip in managedIPs() {
            try? apply(ip: ip, hosts: [], active: false)
        }
    }
```

- [ ] **Step 2: Call it at helper startup**

In `Sources/SproutHelper/main.swift`, insert the sweep just before `listener.resume()`:

```swift
let listener = NSXPCListener(machServiceName: sproutHelperMachServiceName)
listener.delegate = delegate

// Clear stale aliases/hosts left by a crash or reboot before serving requests.
PrivilegedEffects.clearAllManaged()

listener.resume()
```

- [ ] **Step 3: Build to verify**

Run: `swift build`
Expected: builds clean, no warnings.

- [ ] **Step 4: Commit**

```bash
git add Sources/SproutHelper/PrivilegedEffects.swift Sources/SproutHelper/main.swift
git commit -m "feat: clear stale loopback aliases on helper boot"
```

---

### Task 3: App `Info.plist`

**Files:**
- Create: `packaging/Info.plist`

`LSUIElement` is true because Sprout is a menu-bar / accessory app (matches the existing `AppDelegate` `.regular`-on-launch behavior — the plist still declares it an agent). `CFBundleIdentifier` must equal `SproutSigning.appIdentifier` (`com.sprout.app`), because the designated identifier the helper pins derives from it.

- [ ] **Step 1: Write the plist**

Create `packaging/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.sprout.app</string>
    <key>CFBundleName</key>
    <string>Sprout</string>
    <key>CFBundleDisplayName</key>
    <string>Sprout</string>
    <key>CFBundleExecutable</key>
    <string>SproutApp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 2: Validate it parses**

Run: `plutil -lint packaging/Info.plist`
Expected: `packaging/Info.plist: OK`

- [ ] **Step 3: Commit**

```bash
git add packaging/Info.plist
git commit -m "feat: add Sprout.app Info.plist template"
```

---

### Task 4: Helper LaunchDaemon plist

**Files:**
- Create: `packaging/com.sprout.helper.plist`

`SMAppService.daemon(plistName:)` (the app uses `daemonPlistName = "com.sprout.helper"`) loads `Contents/Library/LaunchDaemons/<plistName>.plist`. `BundleProgram` is the helper binary path relative to the `.app` bundle root. `MachServices` must publish exactly the name the code uses (`sproutHelperMachServiceName == "com.sprout.helper.xpc"`). `RunAtLoad` triggers the Task 2 boot sweep.

- [ ] **Step 1: Write the plist**

Create `packaging/com.sprout.helper.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.sprout.helper</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/com.sprout.helper</string>
    <key>MachServices</key>
    <dict>
        <key>com.sprout.helper.xpc</key>
        <true/>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>com.sprout.app</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 2: Validate it parses**

Run: `plutil -lint packaging/com.sprout.helper.plist`
Expected: `packaging/com.sprout.helper.plist: OK`

- [ ] **Step 3: Commit**

```bash
git add packaging/com.sprout.helper.plist
git commit -m "feat: add com.sprout.helper LaunchDaemon plist"
```

---

### Task 5: `scripts/gen-cert.sh` — self-signed cert + regenerate constant

**Files:**
- Create: `scripts/gen-cert.sh` (executable)

This resolves the chicken/egg: the pinned requirement embeds a hash that only exists after the cert is made. The script mints a self-signed code-signing cert into the login keychain, computes its leaf SHA-256 (DER, the form `H"..."` expects), prints it, and rewrites the `leafCertSHA256Hex` line in `SigningConstants.swift`.

No automated test (it touches the login keychain). Verified manually in Task 8.

- [ ] **Step 1: Write the script**

Create `scripts/gen-cert.sh`:

```bash
#!/usr/bin/env bash
# Mint a self-signed "Sprout Dev" code-signing cert in the login keychain and
# regenerate the pinned leaf-cert hash in SigningConstants.swift.
#
# Re-run only when regenerating the cert. Do NOT commit the regenerated hash —
# it is local to this machine; the placeholder in git is what belongs there.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${SPROUT_SIGN_IDENTITY:-Sprout Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
CONST="$ROOT/Sources/SproutEngine/Loopback/SigningConstants.swift"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

echo "==> generating self-signed cert: $NAME"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.cnf"

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/identity.p12" -passout pass:

echo "==> importing into login keychain (codesign-accessible)"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "" -T /usr/bin/codesign

# Leaf SHA-256 over the DER cert — the form the requirement H"..." literal wants.
HASH="$(openssl x509 -in "$TMP/cert.pem" -outform DER \
    | shasum -a 256 | awk '{print $1}' | tr 'a-f' 'A-F')"
echo "==> leaf cert SHA-256: $HASH"

echo "==> rewriting $CONST"
# Replace the 64-hex placeholder/previous value on the leafCertSHA256Hex line.
/usr/bin/sed -i '' -E \
    "s/(leafCertSHA256Hex =)?[[:space:]]*\"[0-9A-Fa-f]{64}\"/\"$HASH\"/" \
    "$CONST"

echo "==> done. Verify with: git diff $CONST"
echo "    (do not commit the regenerated hash)"
```

- [ ] **Step 2: Make it executable + lint shell syntax**

Run:
```bash
chmod +x scripts/gen-cert.sh
bash -n scripts/gen-cert.sh
```
Expected: no output (syntax OK).

- [ ] **Step 3: Commit**

```bash
git add scripts/gen-cert.sh
git commit -m "feat: add gen-cert.sh self-signed cert bootstrap"
```

---

### Task 6: `scripts/bundle.sh` — assemble + sign inside-out

**Files:**
- Create: `scripts/bundle.sh` (executable)

Assembles `build/Sprout.app`, copies the two release binaries, drops the plists in place, then signs inside-out (helper, app binary, outer `.app`) with the one `Sprout Dev` identity so both pinned-hash requirements resolve.

No automated test — signing needs the cert from Task 5 and can't run on unsigned CI. Verified manually in Task 8.

- [ ] **Step 1: Write the script**

Create `scripts/bundle.sh`:

```bash
#!/usr/bin/env bash
# Build, assemble, and code-sign Sprout.app (app + root helper + LaunchDaemon).
# Requires `make certs` to have run first (signing identity in the keychain and
# the matching leaf hash in SigningConstants.swift).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/release"
APP="$ROOT/build/Sprout.app"
IDENTITY="${SPROUT_SIGN_IDENTITY:-Sprout Dev}"

echo "==> swift build -c release"
swift build -c release --package-path "$ROOT"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Library/LaunchDaemons"

cp "$BUILD/SproutApp"     "$APP/Contents/MacOS/SproutApp"
cp "$BUILD/sprout-helper" "$APP/Contents/MacOS/com.sprout.helper"
cp "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/packaging/com.sprout.helper.plist" \
    "$APP/Contents/Library/LaunchDaemons/com.sprout.helper.plist"

echo "==> signing inside-out with identity: $IDENTITY"
# Helper first (innermost), then the app binary, then the outer bundle. Both
# binaries take their designated identifier explicitly so the pinned
# `identifier "..."` requirements match.
codesign --force --options runtime \
    -i com.sprout.helper -s "$IDENTITY" \
    "$APP/Contents/MacOS/com.sprout.helper"
codesign --force --options runtime \
    -i com.sprout.app -s "$IDENTITY" \
    "$APP/Contents/MacOS/SproutApp"
codesign --force --options runtime \
    -i com.sprout.app -s "$IDENTITY" \
    "$APP"

echo "==> verifying signatures"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> designated requirements (sanity):"
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p'
codesign -d -r- "$APP/Contents/MacOS/com.sprout.helper" 2>&1 \
    | sed -n 's/^designated => //p'

echo "==> built: $APP"
```

- [ ] **Step 2: Make it executable + lint shell syntax**

Run:
```bash
chmod +x scripts/bundle.sh
bash -n scripts/bundle.sh
```
Expected: no output (syntax OK).

- [ ] **Step 3: Commit**

```bash
git add scripts/bundle.sh
git commit -m "feat: add bundle.sh to assemble and sign Sprout.app"
```

---

### Task 7: `Makefile` + `.gitignore`

**Files:**
- Create: `Makefile`
- Modify: `.gitignore`

- [ ] **Step 1: Write the Makefile**

Create `Makefile`:

```make
.PHONY: certs app install clean

# Mint the self-signed signing cert and regenerate the pinned leaf hash.
certs:
	./scripts/gen-cert.sh

# Build + assemble + sign Sprout.app into build/.
app:
	./scripts/bundle.sh

# Build the app, then hand off to the user to install + approve the helper.
install: app
	@echo ""
	@echo "Built build/Sprout.app."
	@echo "1. Copy it to /Applications (or run it in place)."
	@echo "2. Launch it; the app registers the helper via SMAppService,"
	@echo "   triggering one admin auth prompt (Touch ID / password)."
	@echo "3. If status shows 'Needs approval', open System Settings >"
	@echo "   General > Login Items and enable Sprout."

clean:
	rm -rf build
```

- [ ] **Step 2: Ignore the build output**

Read `.gitignore` first, then append (if not already present) a line:

```
build/
```

- [ ] **Step 3: Verify make targets parse**

Run: `make -n app`
Expected: prints `./scripts/bundle.sh` (dry run, no execution).

- [ ] **Step 4: Commit**

```bash
git add Makefile .gitignore
git commit -m "feat: add make certs/app/install targets"
```

---

### Task 8: Manual verification checklist

**Files:**
- Create: `docs/MANUAL-VERIFICATION-2b-3.md`

The signed path can't run on unsigned CI, so capture the human verification steps. This is documentation, not code — no test.

- [ ] **Step 1: Write the checklist**

Create `docs/MANUAL-VERIFICATION-2b-3.md`:

```markdown
# Manual Verification — Plan 2b-3 (bundling + signing)

Run on a real macOS 14+ box. The signed privileged path cannot be exercised on
unsigned CI.

## Prerequisites
- [ ] `swift build` and `swift test` pass (the off-by-default loopback feature
      is unaffected).

## Cert bootstrap
- [ ] `make certs` completes; prints a 64-hex leaf SHA-256.
- [ ] `security find-identity -v -p codesigning` lists "Sprout Dev".
- [ ] `git diff Sources/SproutEngine/Loopback/SigningConstants.swift` shows the
      `leafCertSHA256Hex` line changed to the printed hash. **Do not commit it.**

## Bundle + sign
- [ ] `make app` completes; `build/Sprout.app` exists with:
      `Contents/Info.plist`, `Contents/MacOS/SproutApp`,
      `Contents/MacOS/com.sprout.helper`,
      `Contents/Library/LaunchDaemons/com.sprout.helper.plist`.
- [ ] `codesign --verify --deep --strict build/Sprout.app` exits 0.
- [ ] `codesign -d -r- build/Sprout.app` designated requirement names
      `com.sprout.app` and the leaf hash.

## Register the helper
- [ ] Enable loopback: `defaults write <app-domain> loopbackEnabled -bool YES`.
- [ ] Launch `build/Sprout.app`. Settings > Loopback Helper shows status.
- [ ] Use Install (or first-launch register): one admin auth prompt appears.
- [ ] Status becomes "Installed" (or deep-links to Login Items for approval).
- [ ] `launchctl print system/com.sprout.helper` shows the daemon loaded.

## End-to-end provision
- [ ] Start a workspace process. Confirm a `127.0.10.N` alias appears:
      `ifconfig lo0 | grep 127.0.10`.
- [ ] `/etc/hosts` contains the SPROUT block with `<proc>.<proj>.localhost`.
- [ ] Reach the app at `http://<proc>.<proj>.localhost:<port>`.
- [ ] Stop the last process: alias + hosts entry disappear.

## Boot sweep
- [ ] With an alias/hosts entry present, kill the app uncleanly (leaving state),
      then `sudo launchctl kickstart -k system/com.sprout.helper`.
- [ ] After restart the stale `127.0.10.N` alias and SPROUT hosts block are gone.

## Pin rejection (fail-closed)
- [ ] Re-sign `com.sprout.helper` with a *different* identity, relaunch: the app
      refuses the connection (helper-pin mismatch), surfaced as an AppError.

## Uninstall
- [ ] Use Remove: `.unregister()` runs; daemon unloads; no residual alias/hosts.
```

- [ ] **Step 2: Validate it parses as markdown (lint optional)**

Run: `plutil -lint docs/MANUAL-VERIFICATION-2b-3.md || true`
(Not a plist; this just confirms the file exists — `ls docs/MANUAL-VERIFICATION-2b-3.md` is sufficient.)

- [ ] **Step 3: Commit**

```bash
git add docs/MANUAL-VERIFICATION-2b-3.md
git commit -m "docs: manual verification checklist for signed loopback path"
```

---

## Self-Review

**Spec coverage** (design lines 260–376):
- Bundle layout (Info.plist, MacOS/SproutApp, MacOS/com.sprout.helper, LaunchDaemons plist) → Tasks 3, 4, 6.
- `scripts/bundle.sh` via `make app` (build → assemble → sign inside-out → print hash) → Tasks 6, 7.
- Cert + pinned-hash bootstrap (`make certs` → cert + generated constant) → Tasks 1, 5.
- `Makefile` (`make certs/app/install`) → Task 7.
- Pin wiring (replace both PLACEHOLDER strings) → Task 1.
- Crash recovery #2 helper-boot reaper (`RunAtLoad`) → Tasks 2, 4.
- Self-signed/local-only, no notarization → honored (no Developer ID / notarytool anywhere).
- `swift build`/`swift test` unchanged → honored (build path is make-only).
- Manual verification (unsigned CI can't register) → Task 8.
- NOTE: crash recovery #1 (app-launch sweep via `listManaged()` diff in `ProjectStore`) is **out of scope** here — it belongs to the lifecycle/refcount plan, not the bundling/signing pipeline. The primitives (`listManaged`, `staleManagedIPs`) already exist; this plan only adds the helper-boot reaper, which is the signing-pipeline half.

**Placeholder scan:** No "TBD"/"implement later". The one intentional placeholder is the all-zero `leafCertSHA256Hex` — by design (fail-closed default, rewritten by `make certs`), documented in-code.

**Type/name consistency:** `SproutSigning.appIdentifier`/`helperIdentifier`/`leafCertSHA256Hex`/`appRequirement`/`helperRequirement` used identically in Task 1 code and tests. Mach service name `com.sprout.helper.xpc` matches `sproutHelperMachServiceName` and the plist `MachServices` key. `daemonPlistName = "com.sprout.helper"` matches the plist filename. Binary name `com.sprout.helper` consistent across `BundleProgram`, `bundle.sh` copy target, and `codesign -i`. `PrivilegedEffects.clearAllManaged` (added Task 2) called only from `main.swift` (Task 2).

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-06-06-loopback-bundling-signing.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Note: only Tasks 1–2 have automated tests; Tasks 3–8 (plists/scripts/Makefile/docs) verify via `plutil`/`bash -n`/`make -n` + the manual checklist, since signing can't run unsigned.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
