# Workspace page: process list + detail redesign

## Goal

Replace the segmented-picker ("tab") layout on the workspace show page with a
process **list**, where each row shows status and inline Start/Stop controls.
Clicking a row pushes a **process detail** page that hosts that process's logs.

## Motivation

The current picker forces one process into view at a time and hides overall
status behind a small segmented control. A list gives an at-a-glance status
overview of every process and direct per-row controls; logs move to a focused
detail page reached on demand.

## Scope

In scope: `Sources/SproutApp/Views/WorkspaceDetailView.swift` and any new child
views it spawns. Engine and `ProjectStore` lifecycle methods are reused as-is.

Out of scope: the engine, `ProjectStore` business logic, the project overview
page, the menu bar, detached log/console windows (reused, not redesigned).

## User-confirmed decisions

- Navigation: **push/back stack**. List is the root; selecting a process pushes
  a detail page with a back button.
- Consoles: **removed** from this page. No console section, picker, or start
  menu here. Console code in `ProjectStore` and the `DetachedConsoleWindow`
  scene remain in the codebase (left without a UI entry point) — not deleted in
  this change.
- Keep: **Inspector** panel, **Shell drawer (⌘J)**, **Teardown actions** (Push /
  Done / Discard with confirm dialogs + dirty check).
- Remove: segmented picker, console UI, and the **Start all / Stop all** toolbar
  buttons (per-row Start/Stop replaces them).

## Architecture

`WorkspaceDetailView` becomes the host of a `NavigationStack`. The inspector,
shell drawer, and teardown actions/dialogs stay attached at this outer level so
they are present at any stack depth. The stack contains two child views:

```
WorkspaceDetailView (NavigationStack host)
├─ .inspector(...)            ← kept: metadata + open actions
├─ ShellDrawer (when ⌘J)      ← kept
├─ .toolbar { teardown menu, inspector toggle }  ← Start/Stop-all removed
└─ NavigationStack(path)
   ├─ ProcessListView          (root)
   └─ navigationDestination → ProcessDetailView(name)
```

### ProcessListView (stack root)

- One row per entry in `project.config.run.processes`, in config order.
- Status is read from `rec.processes.first(where: name)?.status`
  (`.running` / `.crashed` / else idle).
- Row contents (leading → trailing):
  - status dot: `circle.fill`, semantic color — `.green` running, `.red`
    crashed, `.secondary` idle.
  - process name (primary label).
  - port badge `:<port>` when the process binds a port (`.caption.monospaced`,
    `.secondary`); omitted otherwise.
  - inline `Start` (`play.fill`) and `Stop` (`stop.fill`) buttons.
- The row body is a `NavigationLink(value: name)` → pushes detail. The inline
  Start/Stop buttons use `.buttonStyle(.borderless)` so taps hit the buttons,
  not the navigation link.
- Empty state: when the workspace defines no processes, show
  `ContentUnavailableView` ("No processes").

### ProcessDetailView (pushed)

- `.navigationTitle(name)` with a back button supplied by `NavigationStack`.
- Toolbar (primary action): `Start` (`play.fill`), `Stop` (`stop.fill`),
  `Restart` (`arrow.clockwise`), `Pop out` (`rectangle.portrait.and.arrow.right`).
- Body: `LogConsoleView(buffer: project.logBuffer(branch:process:), onPopOut:)`
  — the existing log view and pop-out window, unchanged.

### Lifecycle wiring

All actions reuse existing `@MainActor ProjectStore` methods:
`startProcess(_:name:)`, `stopProcess(_:name:)`, `restartProcess(_:name:)`.
Calls run through the existing `run { ... }` busy-wrapper pattern.

### Button enablement (status-aware)

- Start: disabled when the process is already `.running`, and when
  `item.orphaned`.
- Stop: disabled when not `.running`.
- Restart (detail only): disabled when `item.orphaned`.

## Apple HIG alignment

- **Clarity:** SF Symbols for every control; semantic system colors for status
  (no hard-coded RGB). Status legible at a glance via the leading dot + native
  list row typography.
- **Deference:** native `List` (`.inset`/sidebar-appropriate style), standard
  `NavigationStack` push/back so the platform owns the back affordance and
  animation. No custom chrome competing with content.
- **Depth:** drilling list → detail uses the system navigation transition; the
  inspector and shell drawer remain as secondary surfaces.
- **Controls:** inline row buttons use `.borderless` with `.help(...)` tooltips
  and accessibility labels; toolbar uses `ToolbarItemGroup(.primaryAction)`.
  Disabled states communicate availability rather than hiding controls.
- **Feedback:** the busy spinner pattern (existing `busy` state) shows during
  async lifecycle actions.

## Testing

The redesign is presentation-only over existing, already-tested store methods.
Verification is manual (SwiftUI views are not unit-tested in this project):

1. Build warning-free (`swift build`); existing suite still green
   (`swift test`).
2. Manual: list shows all processes with correct status dots/ports; per-row
   Start/Stop drive the right process; row tap pushes detail; detail logs stream
   and pop out; back returns to list; inspector, ⌘J drawer, and teardown
   actions still work.

## Risks / notes

- Removing Start-all/Stop-all means starting a fresh workspace is per-row.
  Accepted by user.
- Console UI removal leaves `ProjectStore` console methods + the
  `DetachedConsoleWindow` scene without a caller. Left in place intentionally;
  a later change may remove the dead path.
