# Tabbed project config form

## Goal

Reorganize the project config form from one long scroll into a 4-tab layout. The form
is shared by the project show page (`ProjectOverviewView`) and the new-project sheet
(`CreateProjectSheet`); both adopt tabs.

## Scope

- File: `Sources/SproutApp/Views/ConfigFormView.swift`.
- No changes to `ConfigDraft`, `Config`, or `build()` validation.
- No new files, no new public types.

## Tabs

Top segmented `TabView` (native macOS style). One shared `ConfigDraft` backs all tabs.

| Tab | Sections |
|-----|----------|
| **Basic Info** | Project name; Worktree (base dir, branch prefix); Port range; `extra()` slot |
| **Configurations** | Database (create / drop / URL template); Setup steps; Run server command |
| **Environment** | Symlinked files (sources + `SymlinkSourceRow` preview); local `.env` file |
| **Hooks** | Pre-teardown; Post-teardown |

`extra()` slot renders Doctor on the show page; `CreateProjectSheet` passes `EmptyView`
(existing convenience init already does this). The slot lives inside the Basic Info tab.

## Structure

```
VStack(spacing: 0) {
  TabView(selection: $tab) {
    basicTab  .tabItem { Label("Basic Info",     systemImage: "info.circle") }.tag(FormTab.basic)
    configTab .tabItem { Label("Configurations", systemImage: "slider.horizontal.3") }.tag(FormTab.config)
    envTab    .tabItem { Label("Environment",    systemImage: "key") }.tag(FormTab.env)
    hooksTab  .tabItem { Label("Hooks",          systemImage: "bolt") }.tag(FormTab.hooks)
  }
}
.safeAreaInset(edge: .bottom) { saveBar }
```

- Each `*Tab` is a `@ViewBuilder` computed var wrapping its `Section`s in
  `Form { ... }.formStyle(.grouped)`.
- New private state: `@State private var tab: FormTab = .basic`.
- New private `enum FormTab { case basic, config, env, hooks }`.

## Save & errors

- Single Save / Create button in the bottom bar (`safeAreaInset`), persists across tabs.
- `save()` calls `draft.build()` → validates the **entire** config regardless of active
  tab. Logic unchanged.
- Error banner moves from inline-in-form to the bottom save bar, so a validation error
  is visible from any tab. `saved` flash logic unchanged.

## Out of scope (YAGNI)

- Auto-switching to the tab containing an invalid field. Would couple `DraftError` → tab.
  Banner names the field; user navigates. Revisit if rough.

## Testing

No SwiftUI/view test infra in this repo (engine + registry unit tests only). `build()`
validation is unchanged, so behavior is preserved. Verification = `swift build` + manual
run of the app.
