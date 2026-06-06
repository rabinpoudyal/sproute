# Manual Verification — Plan 2b-3 (bundling + signing)

Run on a real macOS 14+ box. The signed privileged path cannot be exercised on
unsigned CI.

## Prerequisites
- [ ] `swift build` and `swift test` pass (the off-by-default loopback feature
      is unaffected).

## Cert bootstrap
- [ ] `make certs` completes; prints a 40-hex leaf SHA-1.
- [ ] `security find-identity -v -p codesigning` lists "Sprout Dev".
- [ ] `git diff Sources/SproutEngine/Loopback/SigningConstants.swift` shows the
      `leafCertSHA1Hex` line changed to the printed hash. **Do not commit it.**

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

## App-launch sweep (crash recovery, helper still running)
- [ ] With aliases/hosts present from a running workspace, force-quit the app
      (do NOT reboot — the helper stays loaded).
- [ ] Relaunch the app. On startup the stale `127.0.10.N` aliases and their
      SPROUT hosts lines are cleared (nothing is running yet → clean slate).
- [ ] A workspace whose process genuinely survived the crash (pid still alive)
      keeps its alias — its IP is in the live set, so the sweep skips it.

## Pin rejection (fail-closed)
- [ ] Re-sign `com.sprout.helper` with a *different* identity, relaunch: the app
      refuses the connection (helper-pin mismatch), surfaced as an AppError.

## Uninstall
- [ ] Use Remove: `.unregister()` runs; daemon unloads; no residual alias/hosts.
