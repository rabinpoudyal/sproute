# Single Active Workspace & Per-Process Ports

Date: 2026-06-02
Status: Approved (design), pending implementation plan

## Problem

A workspace can define multiple `[[run.process]]` entries (e.g. `web` + `vite`).
Today every process renders the same `{{port}}` and receives the same `PORT`
env var (a single `rec.port` per workspace). Two processes that each bind a
socket therefore collide. Separately, running several workspaces at once
multiplies the number of live dev servers and ports in play, which the user
does not want.

## Goals

1. Only one workspace per project runs at a time. Starting (or creating) a
   workspace stops all running **processes and consoles** belonging to other
   branches in that project.
2. Within a workspace, each port-binding process gets its own distinct port.
3. Because (1) guarantees no two workspaces run simultaneously, ports are
   **deterministic and identical across workspaces** (e.g. `web` is always
   4000, `vite` always 4001). No dynamic per-workspace allocation.

## Non-goals

- Cross-project coordination. The single-active rule is scoped to one project.
- Allocating ports for interactive consoles (REPLs don't bind a listen port).
- Preserving the old dynamic `PortAllocator` behavior — it is removed.

## Part 1 — Single active workspace per project

All start paths live in `ProjectStore` (`Sources/SproutApp/Model/ProjectStore.swift`).

Add a private helper:

```swift
private func stopOthers(exceptBranch branch: String) async
```

It stops, for every branch != `branch` in this project:
- each entry in `supervisors` whose key branch differs → `await sup.stop(graceSeconds: 5)`,
  clear the supervisor, mark its persisted `ProcessState` stopped.
- each console on another branch → stop its controller + `consoleSupervisor.stop(id:)`,
  drop it from `consoleSessions`.

Call `stopOthers(exceptBranch:)` at the top of:
- `startProcess` (covers `startAll`, which loops `startProcess`)
- `startConsole`
- `create` (it auto-launches processes), before `manager.create` starts them

`stopAll`/`stopProcess`/`stopConsole` are unchanged.

Reuse the existing per-process stop bookkeeping (the same `store.upsert` +
`refresh()` that `stopProcess` already performs) so the UI shows the other
workspace's processes as `.stopped`.

## Part 2 — Per-process fixed ports

### Config schema (`.sprout.toml`)

`[[run.process]]` gains an optional boolean `port` (default `false`):

```toml
[[run.process]]
name = "web"
command = "bin/rails server -p {{port}}"
port = true

[[run.process]]
name = "vite"
command = "bin/vite dev --port {{port}}"
port = true

[[run.process]]
name = "worker"
command = "bin/jobs"          # no port key → binds nothing
```

`ProcessConfig` (`Sources/SproutEngine/Config/Config.swift`) gains
`public var bindsPort: Bool`. `TOMLConfigLoader` reads `pt["port"]?.bool ?? false`.
`TOMLConfigWriter` writes `port = true` only when set (omit when false).

### Port assignment

Port-binding processes are numbered in declaration order. Process at
port-index `i` gets `config.port.lower + i`.

- `web` (index 0) → `lower` (4000)
- `vite` (index 1) → `lower + 1` (4001)
- `worker` → no port

The **primary port** = `config.port.lower` (the first binder, or just `lower`
when none bind). `WorkspaceRecord.port` keeps storing this primary value, used
for the browser-open action and the `.env.local` file.

A single helper computes the map once from config:

```swift
// New, engine-side (e.g. Config or a small PortPlan type)
func portPlan(_ config: Config) -> [String: Int]   // process name → port
```

`config.port.upper` is used only to validate that the number of binders fits
in `[lower, upper]`; exceeding it is a config error surfaced as `ConfigError`.

### Template changes (`TemplateRenderer` / `TemplateContext`)

`TemplateContext` gains `ports: [String: Int]` (all binders by name). Render
adds, for each entry, `{{port.<name>}}` → that port. `{{port}}` continues to
mean "this render's port" (the owning process's own port, or the primary at
workspace scope).

This satisfies cross-references (Rails knowing Vite's port):
`VITE_PORT={{port.vite}}`.

### Threading own-port per process

`ProjectStore.context(_:)` and `childEnv(_:)` take an optional process name:

```swift
private func context(_ rec: WorkspaceRecord, process name: String? = nil) -> TemplateContext
private func childEnv(_ rec: WorkspaceRecord, process name: String? = nil) -> [String: String]
```

- `port` field = `portPlan[name]` when `name` binds a port, else primary.
- `ports` field = full plan (so `{{port.x}}` always resolves).
- `childEnv` sets `PORT` = that process's own port.

`startProcess` passes the process name. `WorkspaceManager.create` does the same
per-process when launching each `[[run.process]]` (its current single shared
`ctx`/`childEnv` is replaced by a per-process one inside the launch loop).
Setup steps keep using the primary-port context.

### Removing dynamic allocation

`PortAllocator` (`Sources/SproutEngine/Port/PortAllocator.swift`) and its
injection are removed:
- `WorkspaceManager` drops the `portAllocator` stored property + init param;
  `create` sets `port = config.port.lower` instead of `allocate()`.
- `ProjectStore.makeManager` and `sprout-cli/Sprout.swift` stop constructing a
  `PortAllocator`.
- `PortAllocatorTests.swift` is deleted; `WorkspaceManagerTests` updated to the
  new constructor.
- `BindPortProber` / `PortProber` are removed if nothing else uses them
  (verify during implementation).

`.env.local` (`EnvLinker.writeLocal`) keeps its single `port` param, now the
primary port. Signature unchanged.

## State / migration

`WorkspaceRecord.port` is unchanged on disk (still the primary). Existing
records remain valid; their stored port is simply ignored in favor of the
deterministic plan at runtime, except as the primary for browser/`.env`.
No Codable migration required.

## UI changes

`WorkspaceDetailView` inspector currently shows one `Port` field. Replace with
one row per port-binding process, e.g.:

```
Ports
  web    :4000
  vite   :4001
```

Derived from the same `portPlan(config)`. The process selector bar and log/
console panes are unchanged.

## Testing

- `ConfigLoaderTests`: `port = true` parsed; absent → false; round-trip via writer.
- New `PortPlanTests`: ordering/offset; processes without `port` excluded;
  >range → `ConfigError`.
- `TemplateRendererTests`: `{{port}}` (own) and `{{port.<name>}}` (sibling).
- `WorkspaceManagerTests`: create launches each process with its own
  PORT/`{{port}}`; constructor updated (no allocator).
- `ProjectStoreTests` (or integration): starting workspace B stops workspace A's
  processes + consoles. (Gate real-process bits behind `SPROUT_INTEGRATION`.)
- Delete `PortAllocatorTests`.

## Open risks

- A crashed/orphaned process from a prior session could still hold a fixed port
  when the next workspace starts. `stopOthers` only stops processes Sprout still
  tracks in `supervisors`. Mitigation: on `startProcess`, the existing
  pre-terminate of a recorded pid helps; fully reaping untracked orphans on the
  same fixed port is out of scope for this change.
