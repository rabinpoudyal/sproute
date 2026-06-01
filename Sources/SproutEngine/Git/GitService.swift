import Foundation

public enum GitError: Error, Equatable {
    case commandFailed(command: String, exitCode: Int32, stderr: String)
}

public struct GitService: Sendable {
    let shell: ShellRunner
    public init(shell: ShellRunner) { self.shell = shell }

    /// Single-quote-escape an argument for the shell.
    private func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    private func runChecked(_ command: String, cwd: URL) async throws -> ProcessResult {
        let r = try await shell.run(command, cwd: cwd, env: [:])
        guard r.succeeded else {
            throw GitError.commandFailed(command: command, exitCode: r.exitCode, stderr: r.stderr)
        }
        return r
    }

    public func fetch(repo: URL) async throws {
        try await runChecked("git fetch --all --prune", cwd: repo)
    }

    public func branches(repo: URL) async throws -> [String] {
        let r = try await runChecked("git branch -a", cwd: repo)
        return r.stdout
            .split(separator: "\n")
            .map { $0.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public func worktreeAdd(repo: URL, path: String, base: String, branch: String) async throws {
        try await runChecked("git worktree add -b \(q(branch)) \(q(path)) \(q(base))", cwd: repo)
    }

    public func worktreeRemove(repo: URL, path: String) async throws {
        try await runChecked("git worktree remove --force \(q(path))", cwd: repo)
    }

    public func isDirty(worktree: URL) async throws -> Bool {
        let r = try await runChecked("git status --porcelain", cwd: worktree)
        return !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func push(worktree: URL, branch: String) async throws {
        try await runChecked("git push -u origin \(q(branch))", cwd: worktree)
    }

    public func deleteBranch(repo: URL, branch: String) async throws {
        try await runChecked("git branch -D \(q(branch))", cwd: repo)
    }
}
