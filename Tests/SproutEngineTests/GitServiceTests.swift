import Testing
import Foundation
@testable import SproutEngine

private let repo = URL(fileURLWithPath: "/repo")
private let wt = URL(fileURLWithPath: "/wt/login")

@Test func worktreeAddBuildsExpectedCommand() async throws {
    let shell = FakeShellRunner()
    let git = GitService(shell: shell)
    try await git.worktreeAdd(repo: repo, path: "/wt/login", base: "main", branch: "feature/login")
    #expect(
        shell.calls.last?.command
            == "git worktree add -b 'feature/login' '/wt/login' 'main'")
    #expect(shell.calls.last?.cwd == "/repo")
}

@Test func pushBuildsExpectedCommand() async throws {
    let shell = FakeShellRunner()
    let git = GitService(shell: shell)
    try await git.push(worktree: wt, branch: "feature/login")
    #expect(shell.calls.last?.command == "git push -u origin 'feature/login'")
    #expect(shell.calls.last?.cwd == "/wt/login")
}

@Test func isDirtyTrueWhenStatusNonEmpty() async throws {
    let shell = FakeShellRunner()
    shell.runResults = [
        (
            "status --porcelain",
            ProcessResult(stdout: " M file.txt\n", stderr: "", exitCode: 0)
        )
    ]
    let git = GitService(shell: shell)
    #expect(try await git.isDirty(worktree: wt) == true)
}

@Test func isDirtyFalseWhenStatusEmpty() async throws {
    let shell = FakeShellRunner()
    shell.runResults = [
        (
            "status --porcelain",
            ProcessResult(stdout: "", stderr: "", exitCode: 0)
        )
    ]
    let git = GitService(shell: shell)
    #expect(try await git.isDirty(worktree: wt) == false)
}

@Test func branchesParsesAndStripsMarkers() async throws {
    let shell = FakeShellRunner()
    shell.runResults = [
        (
            "branch -a",
            ProcessResult(
                stdout: "* main\n  develop\n  remotes/origin/feature/x\n",
                stderr: "", exitCode: 0)
        )
    ]
    let git = GitService(shell: shell)
    let branches = try await git.branches(repo: repo)
    #expect(branches == ["main", "develop", "remotes/origin/feature/x"])
}

@Test func nonZeroExitThrows() async {
    let shell = FakeShellRunner()
    shell.runResults = [("push", ProcessResult(stdout: "", stderr: "rejected", exitCode: 1))]
    let git = GitService(shell: shell)
    await #expect(throws: GitError.self) {
        try await git.push(worktree: wt, branch: "x")
    }
}
