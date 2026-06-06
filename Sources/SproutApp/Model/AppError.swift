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
            self.init(
                title: "Git command failed (exit \(exitCode))",
                detail: AppError.clean(stderr) ?? command)
        case let DatabaseError.commandFailed(command, exitCode, stderr):
            self.init(
                title: "Database command failed (exit \(exitCode))",
                detail: AppError.clean(stderr) ?? command)
        case let SetupError.stepFailed(_, name, exitCode):
            self.init(
                title: "Setup step “\(name)” failed (exit \(exitCode))",
                detail: "Check the setup logs for the command output.")
        case TeardownError.dirtyWorktree:
            self.init(title: "Worktree has uncommitted changes")
        case TeardownError.workspaceNotFound:
            self.init(title: "Workspace not found")
        case let ConfigError.missingKey(key):
            self.init(title: "Config is missing a required key", detail: key)
        case let ConfigError.parseFailed(message):
            self.init(title: "Could not parse .sprout.toml", detail: message)
        case ProvisionError.helperUnavailable:
            self.init(
                title: "Loopback helper unavailable",
                detail: "Enable it in Settings ▸ Loopback, then try again.")
        case let ProvisionError.helperRejected(reason):
            self.init(
                title: "Loopback helper rejected the request",
                detail: reason
                    + "\n\nIf you recently updated Sprout, reload the helper: "
                    + "Settings ▸ Loopback, turn the toggle off then on, so the "
                    + "latest version is running.")
        case let ProvisionError.ifconfigFailed(message):
            self.init(title: "Could not configure loopback alias", detail: message)
        case let ProvisionError.hostsWriteFailed(message):
            self.init(title: "Could not update /etc/hosts", detail: message)
        default:
            self.init(title: "Something went wrong", detail: "\(error)")
        }
    }

    private static func clean(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
