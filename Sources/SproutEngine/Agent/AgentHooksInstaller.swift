import Foundation

/// Writes the Claude Code hook configuration that makes a launched `claude`
/// session call back into Sprout. Hooks land in the worktree's
/// `.claude/settings.local.json` — a file Claude Code reads for project-local
/// settings and auto-gitignores, so we never touch tracked files.
public enum AgentHooksInstaller {
    /// Every hook event we register. Names Claude Code doesn't know are ignored,
    /// so over-registering is safe and future-proofs against renamed events.
    static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "Notification", "PermissionRequest", "Stop",
        "SubagentStop", "SessionEnd",
    ]

    /// The fire-and-forget command each hook runs: POST the JSON on stdin to our
    /// loopback endpoint. `-s` silences curl, `-m 5` caps it so a stalled receiver
    /// can never block Claude, and `/hook/<token>` identifies this agent.
    static func hookCommand(port: UInt16, token: String) -> String {
        "curl -s -m 5 -X POST http://127.0.0.1:\(port)/hook/\(token)"
            + " -H 'Content-Type: application/json' -d @-"
    }

    /// The `hooks` object to merge into settings: one command hook per event,
    /// matcher `""` (all). Kept as `[String: Any]` so `install` can merge it into
    /// an existing settings file without disturbing other keys.
    static func hooksObject(port: UInt16, token: String) -> [String: Any] {
        let command = hookCommand(port: port, token: token)
        let entry: [String: Any] = [
            "matcher": "",
            "hooks": [["type": "command", "command": command]],
        ]
        var hooks: [String: Any] = [:]
        for event in events { hooks[event] = [entry] }
        return hooks
    }

    /// A standalone `settings.local.json` string with just our hooks. Used for
    /// tests and as the seed when no settings file exists yet.
    public static func settingsJSON(port: UInt16, token: String) -> String {
        let root: [String: Any] = ["hooks": hooksObject(port: port, token: token)]
        let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Merge our hooks into `<worktree>/.claude/settings.local.json`, preserving
    /// any other keys a user already set there. Creates `.claude/` if needed.
    public static func install(worktree: URL, port: UInt16, token: String) throws {
        let dir = worktree.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.local.json")

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: file),
            let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            root = existing
        }
        root["hooks"] = hooksObject(port: port, token: token)
        let out = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: file, options: .atomic)
    }
}
