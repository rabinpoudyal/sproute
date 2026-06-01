import Foundation
import SproutEngine

/// A user-presentable error: a short title plus optional detail (e.g. command stderr).
struct AppError: Identifiable {
    let id = UUID()
    let title: String
    let detail: String?

    init(title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    init(_ error: Error) {
        switch error {
        case let GitError.commandFailed(command, exitCode, stderr):
            self.init(title: "Git command failed (exit \(exitCode))",
                      detail: AppError.clean(stderr) ?? command)
        case let DatabaseError.commandFailed(command, exitCode, stderr):
            self.init(title: "Database command failed (exit \(exitCode))",
                      detail: AppError.clean(stderr) ?? command)
        case let SetupError.stepFailed(_, name, exitCode):
            self.init(title: "Setup step “\(name)” failed (exit \(exitCode))",
                      detail: "Check the setup logs above for the command output.")
        case PortError.noFreePort:
            self.init(title: "No free port available",
                      detail: "Every port in the configured range is in use. Tear down a workspace or widen the range in .sprout.toml.")
        case TeardownError.dirtyWorktree:
            self.init(title: "Worktree has uncommitted changes")
        case TeardownError.workspaceNotFound:
            self.init(title: "Workspace not found")
        case let ConfigError.missingKey(key):
            self.init(title: "Config is missing a required key", detail: key)
        case let ConfigError.parseFailed(message):
            self.init(title: "Could not parse .sprout.toml", detail: message)
        default:
            self.init(title: "Something went wrong", detail: "\(error)")
        }
    }

    private static func clean(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
