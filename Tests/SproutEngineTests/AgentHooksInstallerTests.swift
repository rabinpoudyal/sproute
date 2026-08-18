import Foundation
import Testing

@testable import SproutEngine

@Suite struct AgentHooksInstallerTests {
    @Test func settingsIncludeEndpointAndEvents() throws {
        // Parse back rather than string-match: JSONSerialization escapes "/" as
        // "\/" (valid JSON that Claude Code decodes fine), so the raw text differs
        // from the logical URL.
        let json = AgentHooksInstaller.settingsJSON(port: 4321, token: "T0K")
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let hooks = try #require(obj?["hooks"] as? [String: Any])
        let expected = [
            "SessionStart", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd",
        ]
        for event in expected {
            #expect(hooks[event] != nil)
        }
        let entry = (hooks["SessionStart"] as? [[String: Any]])?.first
        let command = ((entry?["hooks"] as? [[String: Any]])?.first)?["command"] as? String
        #expect(command?.contains("http://127.0.0.1:4321/hook/T0K") == true)
    }

    @Test func installMergesPreservingOtherKeys() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sprout-hooks-\(UUID().uuidString)")
        let claude = dir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = claude.appendingPathComponent("settings.local.json")
        try Data(#"{"model":"opus","hooks":{"old":[]}}"#.utf8).write(to: file)

        try AgentHooksInstaller.install(worktree: dir, port: 9, token: "z")

        let obj =
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(obj?["model"] as? String == "opus")  // unrelated key preserved
        let hooks = obj?["hooks"] as? [String: Any]
        #expect(hooks?["SessionStart"] != nil)  // ours written
        #expect(hooks?["old"] == nil)  // hooks key fully replaced
    }

    @Test func installCreatesClaudeDirWhenMissing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sprout-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try AgentHooksInstaller.install(worktree: dir, port: 1, token: "t")

        let file = dir.appendingPathComponent(".claude/settings.local.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
