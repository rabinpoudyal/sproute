# Tabbed Project Config Form Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the shared project config form into four tabs (Basic Info, Configurations, Environment, Hooks) with one shared save bar.

**Architecture:** Reorganize `ConfigFormView`'s body into a native macOS `TabView` whose four tabs are `@ViewBuilder` computed vars, each a grouped `Form`. One `ConfigDraft` backs all tabs. A single `saveBar` (with the error banner moved into it) sits in a `safeAreaInset` below the `TabView`, so save/validation behavior is unchanged. Both consumers (`ProjectOverviewView` show page, `CreateProjectSheet`) inherit tabs for free since they already render `ConfigFormView`.

**Tech Stack:** Swift 6, SwiftUI, macOS 14. No new dependencies.

---

## File Structure

- Modify: `Sources/SproutApp/Views/ConfigFormView.swift` — the only file changed. Replace the monolithic `body`'s `Form` with a `TabView` + extracted `saveBar`; add a private `FormTab` enum and `tab` state. `SymlinkSourceRow` (file-private) and the `save()`/`remove()`/`removeStep()`/`confirmSaved()` helpers stay as-is. The `extra()` slot moves into the Basic Info tab.

No other files change: `ConfigDraft`, `Config`, `build()`, `ProjectOverviewView`, and `CreateProjectSheet` are untouched. `ProjectOverviewView` already passes Doctor through `extra`; `CreateProjectSheet`'s convenience init already passes `EmptyView`.

### Testing note

This repo has **no SwiftUI/view test infrastructure** (only engine + registry unit tests via Swift Testing). `build()` validation is unchanged, so this is a pure presentation refactor. Verification per task = `swift build`, `swift format lint`, and a manual run checklist. No new automated tests.

---

## Task 1: Reorganize ConfigFormView into a TabView

**Files:**
- Modify: `Sources/SproutApp/Views/ConfigFormView.swift`

- [ ] **Step 1: Add the tab enum and selection state**

In `struct ConfigFormView`, just below the existing `@State private var saved = false` line, add:

```swift
    @State private var tab: FormTab = .basic

    private enum FormTab: Hashable { case basic, config, env, hooks }
```

- [ ] **Step 2: Replace the `body` with a TabView + save bar**

Replace the entire current `var body: some View { ... }` (the `Form { ... }.formStyle(.grouped).safeAreaInset(...)` block) with:

```swift
    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                basicTab
                    .tabItem { Label("Basic Info", systemImage: "info.circle") }
                    .tag(FormTab.basic)
                configTab
                    .tabItem { Label("Configurations", systemImage: "slider.horizontal.3") }
                    .tag(FormTab.config)
                envTab
                    .tabItem { Label("Environment", systemImage: "key") }
                    .tag(FormTab.env)
                hooksTab
                    .tabItem { Label("Hooks", systemImage: "bolt") }
                    .tag(FormTab.hooks)
            }
        }
        .safeAreaInset(edge: .bottom) { saveBar }
    }
```

- [ ] **Step 3: Add the four tab computed vars**

Immediately after `body`, add:

```swift
    // MARK: tabs

    @ViewBuilder private var basicTab: some View {
        Form {
            Section("Project") {
                TextField("Name", text: $draft.projectName, prompt: Text("my-app"))
            }
            Section("Worktree") {
                TextField("Base dir", text: $draft.baseDir, prompt: Text("../worktrees"))
                TextField("Branch prefix", text: $draft.branchPrefix, prompt: Text("feature/"))
            }
            Section("Port range") {
                TextField("Lower", text: $draft.portLower)
                TextField("Upper", text: $draft.portUpper)
            }
            extra()
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var configTab: some View {
        Form {
            Section("Database") {
                TextField("Create", text: $draft.dbCreate)
                TextField("Drop", text: $draft.dbDrop)
                TextField("URL template", text: $draft.dbURL)
            }
            Section("Setup steps") {
                ForEach($draft.setup) { $step in
                    HStack {
                        TextField("name", text: $step.name)
                            .frame(width: 110)
                        TextField("command", text: $step.command)
                            .font(.callout.monospaced())
                        Button(role: .destructive) {
                            removeStep(step.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button {
                    draft.setup.append(.init(name: "", command: ""))
                } label: {
                    Label("Add step", systemImage: "plus")
                }
            }
            Section("Run") {
                TextField("Server command", text: $draft.serverCommand)
                    .font(.callout.monospaced())
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var envTab: some View {
        Form {
            Section {
                ForEach($draft.symlinkSources) { $source in
                    SymlinkSourceRow(
                        path: $source.value,
                        projectRoot: projectRoot,
                        onDelete: { remove(source.id) })
                }
                Button {
                    draft.symlinkSources.append(.init(value: ""))
                } label: {
                    Label("Add source", systemImage: "plus")
                }
                TextField("Local file", text: $draft.localFile, prompt: Text(".env.local"))
            } header: {
                Text("Symlinked files")
            } footer: {
                Text(
                    "Gitignored secrets identical across branches (e.g. config/master.key). "
                        + "Missing entries are skipped when linking.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var hooksTab: some View {
        Form {
            Section("Hooks (optional)") {
                TextField("Pre-teardown", text: $draft.preTeardown)
                TextField("Post-teardown", text: $draft.postTeardown)
            }
        }
        .formStyle(.grouped)
    }
```

- [ ] **Step 4: Add the extracted save bar**

After the tab vars, add the `saveBar` (this is the old `safeAreaInset` content with the error banner pulled up from inside the form):

```swift
    // MARK: save bar

    private var saveBar: some View {
        VStack(spacing: 8) {
            if let error {
                ErrorBanner(error: AppError(title: "Invalid configuration", detail: error))
            }
            HStack {
                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                Spacer()
                if let onCancel {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
                Button(saveTitle, action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .background(.bar)
    }
```

Leave the existing `remove(_:)`, `removeStep(_:)`, `save()`, and `confirmSaved()` methods, the `extension ConfigFormView where Extra == EmptyView`, and the `private struct SymlinkSourceRow` exactly as they are.

- [ ] **Step 5: Build**

Run: `swift build`
Expected: `Build complete!` with no warnings.

- [ ] **Step 6: Lint**

Run: `swift format lint -r Sources/SproutApp/Views/ConfigFormView.swift`
Expected: no output (clean). Do **not** run `swift format format -i` (it rewraps the intentional compact style).

- [ ] **Step 7: Manual run check**

Run: `swift run SproutApp`
Verify on the project show page:
- Four tabs appear across the top: Basic Info, Configurations, Environment, Hooks.
- Basic Info shows Project / Worktree / Port range **and** the Doctor section (with "Run Doctor").
- Configurations shows Database / Setup steps (add + remove a step) / Run.
- Environment shows the symlink source list (add a source, toggle the eye preview) + Local file.
- Hooks shows Pre-/Post-teardown.
- Editing a field on one tab, switching tabs, and hitting Save persists all fields (re-open the project; values stick).
- Enter an invalid value (e.g. clear Project name on Basic Info, switch to Hooks, hit Save) → the red error banner shows in the bottom bar from the Hooks tab; nothing is saved.
- Open "New Project" sheet → same four tabs; "Create project" button validates across tabs.

- [ ] **Step 8: Commit**

```bash
git add Sources/SproutApp/Views/ConfigFormView.swift
git commit -m "feat(app): tabbed project config form"
```

---

## Self-Review

- **Spec coverage:** Basic Info / Configurations / Environment / Hooks tabs (Steps 3) ✓; field mapping matches spec table ✓; top segmented TabView (Step 2) ✓; single shared save bar + error banner moved to bar (Step 4) ✓; `extra()`/Doctor in Basic Info (Step 3 `basicTab`) ✓; both consumers inherit tabs (no edits needed — noted in File Structure) ✓; no auto-switch on error (YAGNI, omitted) ✓; verification via build + lint + manual run (Steps 5-7) ✓.
- **Placeholder scan:** none — every step has full code or exact commands.
- **Type consistency:** `FormTab` enum + `.tag(FormTab.x)` match; `basicTab`/`configTab`/`envTab`/`hooksTab` names match between `body` and their definitions; `saveBar`, `save()`, `remove(_:)`, `removeStep(_:)`, `SymlinkSourceRow`, `ErrorBanner`, `AppError` all match existing code.
