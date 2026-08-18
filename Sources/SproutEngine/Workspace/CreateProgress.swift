import Foundation

/// A distinct phase of `WorkspaceManager.create`, reported so a UI can show which
/// steps are done, running, or still pending while a workspace is provisioned.
public enum CreatePhase: Sendable, Hashable {
    case loopback  // provision per-branch loopback alias via the helper (XPC)
    case worktree
    case database
    case environment
    case setup(String)  // setup-step name
    case process(String)  // run-process name
}

public enum CreateStepState: Sendable, Hashable {
    case pending, running, done, failed
}
