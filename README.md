# Sprout

Per-branch dev workspaces **and a multi-agent control room** for macOS.

Sprout gives every git branch its own isolated dev workspace — a dedicated
worktree, port, database, symlinked secrets, and a supervised dev server — driven
by a per-project config. On top of that isolation it runs **coding agents**
(Claude Code) inside those workspaces and shows them in a live **Agent World**:
a glanceable view where each agent is a character that moves between rooms
(working / waiting-on-you / idle / done) as it runs, and which you can inspect and
steer without leaving the window.

## Why

Running several coding agents in parallel means several processes editing code at
once — which collides on files, ports, and databases unless each is isolated.
Sprout already solves that isolation for per-branch dev servers, so it's the
natural substrate for parallel agents. The Agent World then makes a fleet of
agents legible: at a glance you can see who's working, who's blocked waiting for
your approval, and who's done.

## Quick start

```sh
swift build            # builds the engine, CLI, and app
swift run SproutApp    # launch the macOS app
```

In the app:

1. **New Project** — point at a repo folder and author its config (stored in your
   home dir, see below). Or **Add Project** to import an existing `.sprout.toml`.
2. Create a **workspace** for a branch — Sprout provisions the worktree, port, DB,
   secrets, and starts the configured processes.
3. Declare an agent with an `[[agent]]` block, then open **Agent World** (top of
   the sidebar) and **Start** it inside a workspace. Watch its state stream live;
   click it to inspect and steer (redirect / approve / stop).

## Configuration

Each project's config is a TOML file kept in your **home directory**, not the
repo, so it isn't shared with collaborators:

```
~/.sprout/
  projects.json          # registered projects: {path, name}
  configs/<name>.toml     # per-project config
  state/<name>.json       # per-workspace runtime state
```

A config declares the worktree base dir, database commands, env/secrets, setup
steps, long-running `[[run.process]]` entries, and `[[agent]]` entries:

```toml
[project]
name = "shop"

[worktree]
base_dir = "../shop-worktrees"
branch_prefix = "feature/"

[[run.process]]
name = "server"
command = "npm run dev -- --host {{host}} --port {{port}}"
port = 4000

[[agent]]
name = "builder"
command = "claude"
```

When you start an agent, Sprout writes a Claude Code hook config into the
worktree's (gitignored) `.claude/settings.local.json` so the session reports its
state back to the app over a loopback endpoint.

## Layout

A Swift package with three products:

- **SproutEngine** (`Sources/SproutEngine/`) — headless library; all real logic.
  Modules: Config, Shell, Git, Database, Port, Env, Setup, Server, State,
  Workspace, **Agent** (hook receiver + state reducer), Console (PTY).
- **sprout** (`Sources/sprout-cli/`) — thin ArgumentParser CLI over the engine.
- **SproutApp** (`Sources/SproutApp/`) — SwiftUI macOS app (multi-project, menu
  bar + window, Agent World, detachable log/console viewers).

The CLI and app are thin clients composing the same engine types.

## Build & test

```sh
swift build
swift test                        # full unit suite (needs the Xcode xctest runner)
SPROUT_INTEGRATION=1 swift test   # also runs integration tests (real git/process/socket)
swift format lint -r Sources Tests
```

Conventions and hard-won gotchas live in [`CLAUDE.md`](CLAUDE.md); design notes in
[`docs/architecture.md`](docs/architecture.md).

## Notes

- **Per-branch loopback IPs** (a privileged helper that gives each branch its own
  `127.0.10.N`) are currently **disabled** — everything binds `127.0.0.1`. The
  code remains in the tree, dormant.
- The macOS app runs unsigned via `swift run`; a signed bundle
  (`./scripts/bundle.sh`) is only needed if the loopback helper is re-enabled.
