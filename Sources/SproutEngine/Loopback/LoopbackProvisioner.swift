import Foundation

public enum ProvisionError: Error, Equatable {
    case helperUnavailable
    case helperRejected(String)
    case ifconfigFailed(String)
    case hostsWriteFailed(String)
}

/// Installs or removes a loopback alias plus its `/etc/hosts` entries for one
/// workspace IP. The real implementation talks to a privileged helper over XPC
/// (follow-up plan); engine and tests depend only on this protocol.
public protocol LoopbackProvisioner: Sendable {
    func setActive(ip: String, hosts: [String], active: Bool) async throws
}

/// Default no-op. Wired into the app until the XPC helper exists, so behavior is
/// unchanged (no aliases created; workspaces keep binding 127.0.0.1).
public struct NoopLoopbackProvisioner: LoopbackProvisioner {
    public init() {}
    public func setActive(ip: String, hosts: [String], active: Bool) async throws {}
}

/// Per-process hostnames for a workspace: `<process>.<project>.localhost` for
/// every port-binding process. Used to populate the `/etc/hosts` managed block.
public func loopbackHostnames(
    project: String,
    processes: [ProcessConfig]
) -> [String] {
    let projectSlug = TemplateContext.slugify(project)
    let portBinders = processes.filter { $0.port != nil }

    return portBinders.map { "\(TemplateContext.slugify($0.name)).\(projectSlug).localhost" }
}
