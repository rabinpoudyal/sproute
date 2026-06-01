# Sprout

Per-branch dev workspaces for macOS. Each git worktree gets its own database, port,
symlinked secrets, and a supervised dev server. Driven by a `.sprout.toml` per project.

## Layout

Swift Package, three products:

- **SproutEngine** (`Sources/SproutEngine/`) — headless library. All real logic lives here.
- **sprout** (`Sources/sprout-cli/`) — thin ArgumentParser CLI over the engine.
- **SproutApp** (`Sources/SproutApp/`) — SwiftUI macOS app (multi-project, menu bar + window, detachable log viewer).

CLI and app are both thin clients; they compose the same engine types and add no business logic.

### Engine modules

`Config` (TOML → `Config`, `{{var}}` template rendering), `Shell` (login-shell command runner),
`Git`, `Database`, `Port` (allocator + prober), `Env` (symlink secrets, write local env file),
`Setup` (run setup steps), `Server` (`actor ServerSupervisor`, process-group lifecycle),
`State` (JSON persistence), `Workspace` (`WorkspaceManager` = create/teardown/reconcile orchestrator,
`DoctorService` toolchain check).

## Build & test

```sh
swift build                              # builds all three products
swift test                               # full suite (requires Xcode for xctest runner)
swift test --filter WorkspaceManagerTests
SPROUT_INTEGRATION=1 swift test          # also runs gated integration tests (real git + process kill)
```

`swift test` needs the Xcode `xctest` runner installed (not just Command Line Tools).
`SproutEngineTests` carries `unsafeFlags` pointing at CommandLineTools frameworks — leave them.

## Conventions

- **Swift 6, strict concurrency.** Keep the build warning-free. `@MainActor` view-models,
  `Sendable` value types, `actor` for stateful concurrency. `@MainActor` types are implicitly
  `Sendable` — capture them in `@Sendable` closures via `Task { @MainActor in ... }`.
- **Dependency injection via protocols.** Engine seams: `ShellRunner`, `FileSystem`, `StateStore`,
  `PortProber`, `ProcessChecker`, `ProcessTerminator`. Tests inject fakes (`Tests/.../Support/`);
  never hit the real shell/fs/git in unit tests. Integration tests (real side effects) are gated
  behind `SPROUT_INTEGRATION`.
- **Testing framework:** Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest.
  Note: `#expect` cannot call a `mutating` method inline — bind to a `let` first.
- **Errors** are typed enums per module (`GitError`, `DatabaseError`, `SetupError`, `PortError`,
  `TeardownError`, `ConfigError`). The app maps them to user-facing text in `AppError`.
- **Style:** 4-space indent, ~100 col soft limit, compact hanging-indent for wrapped calls.
  `.swift-format` config matches this. Lint: `swift format lint -r Sources Tests`. Do **not**
  bulk-reformat with `swift format format -i` — it rewraps the intentional compact style.
- Comments explain *why*, not *what*. Don't add docstrings to unchanged code.

## Gotchas (learned the hard way)

- **Login shell ≠ interactive shell.** `LoginShellRunner` uses `$SHELL -l -c`, which sources
  `.zprofile`/`.zlogin` but **not** `.zshrc`. rbenv/nvm init usually lives in `.zshrc`, so the
  login shell falls back to system ruby/node. Ruby commands in `.sprout.toml` must be prefixed
  with `rbenv exec` (and use `rbenv exec ruby bin/rails`, since `rbenv exec` searches PATH, not
  project binstubs).
- **Relative `base_dir` must resolve against the repo, not the process cwd.** git resolves it
  relative to the repo; `URL(fileURLWithPath:)` would use the app's cwd. `WorkspaceManager.create`
  anchors the worktree path to `repo` so git, symlinks, DB, and state all agree.
- **`git worktree add -b` creates the branch too.** Rollback on a failed create must delete the
  branch + force-remove any leftover dir + `git worktree prune`, or a retry hits "already exists".
- **EnvLinker only symlinks existing sources and does NOT create parent dirs.** Nested sources
  (e.g. `config/master.key`) need their dir already present in the worktree checkout. Only symlink
  gitignored secrets that are identical across branches (master.key, per-env credential keys).
  Never symlink `storage/`, `node_modules`, `vendor/bundle`, builds, `tmp`, `log` — they diverge.
- **CLI vs app server lifetime.** One-shot CLI `create` exits, closing the server's stdout pipe →
  the dev server gets EPIPE and dies. The GUI app keeps pipes open, so it stays alive. Expected.
- **MenuBarExtra launches the app as an accessory** → main window can't take keyboard focus
  (modals won't receive typed input). `AppDelegate` forces `.regular` activation policy on launch.

## State & paths

- Project registry: `~/.sprout/projects.json` (normalized absolute paths).
- Per-project state: `~/.sprout/state/<slug>.json`.
- Worktrees: under the project's configured `worktree.base_dir`.
