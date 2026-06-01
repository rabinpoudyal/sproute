import Testing
import Foundation
@testable import SproutEngine

private var integrationEnabled: Bool {
    ProcessInfo.processInfo.environment["SPROUT_INTEGRATION"] == "1"
}

private func sh(_ cmd: String, cwd: URL) async throws {
    let r = try await LoginShellRunner().run(cmd, cwd: cwd, env: [:])
    #expect(r.exitCode == 0, "command failed: \(cmd)\n\(r.stderr)")
}

@Test(.enabled(if: integrationEnabled))
func realGitWorktreeAddAndRemove() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("sprout-it-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let repo = tmp.appendingPathComponent("repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try await sh("git init -q && git commit -q --allow-empty -m init", cwd: repo)

    let git = GitService(shell: LoginShellRunner())
    let wtPath = tmp.appendingPathComponent("wt-login").path
    try await git.worktreeAdd(repo: repo, path: wtPath, base: "HEAD", branch: "feature/login")
    #expect(FileManager.default.fileExists(atPath: wtPath))

    try await git.worktreeRemove(repo: repo, path: wtPath)
    #expect(!FileManager.default.fileExists(atPath: wtPath))
}

@Test(.enabled(if: integrationEnabled))
func realProcessGroupTerminationKillsChildren() async throws {
    // Launch a shell that spawns a long-lived child; terminate must kill the group.
    let runner = LoginShellRunner()
    let handle = try runner.launch(
        "sleep 600", cwd: FileManager.default.temporaryDirectory, env: [:])
    let pid = handle.pid
    #expect(kill(pid, 0) == 0)  // alive
    await handle.terminate(graceSeconds: 1)
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(kill(pid, 0) != 0)  // dead
}
