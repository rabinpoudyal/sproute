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
    /// IPs the helper currently manages (its `/etc/hosts` block). Used by the
    /// launch sweep to find aliases a crashed app left behind.
    func listManaged() async throws -> [String]
}

/// Default no-op. Wired into the app until the XPC helper exists, so behavior is
/// unchanged (no aliases created; workspaces keep binding 127.0.0.1).
public struct NoopLoopbackProvisioner: LoopbackProvisioner {
    public init() {}
    public func setActive(ip: String, hosts: [String], active: Bool) async throws {}
    public func listManaged() async throws -> [String] { [] }
}

/// Per-process hostnames for a workspace: `<process>.<branch>.<project>.test` for
/// every port-binding process. Used to populate the `/etc/hosts` managed block.
///
/// The `.test` TLD (RFC 6761 reserved) is deliberate: macOS hardcodes every
/// `*.localhost` name to loopback and bypasses `/etc/hosts`, so a `.localhost`
/// host would always resolve to 127.0.0.1 instead of the workspace's IP. `.test`
/// has no special resolution, so the managed `/etc/hosts` entries take effect.
/// The `<branch>` label disambiguates concurrent workspaces of the same project —
/// without it every branch collides on one hostname mapped to multiple IPs.
public func loopbackHostnames(
    project: String,
    branch: String,
    processes: [ProcessConfig]
) -> [String] {
    let projectSlug = hostnameSlug(project)
    let branchSlug = hostnameSlug(branch)
    let portBinders = processes.filter { $0.port != nil }

    return portBinders.map { "\(hostnameSlug($0.name)).\(branchSlug).\(projectSlug).test" }
}

/// DNS-label-safe slug for hostnames: lowercase, collapse runs of non-alphanumeric
/// chars to a single `-`, trim leading/trailing `-`. Distinct from
/// `TemplateContext.slugify` (which uses `_`, valid for db names but not hostnames)
/// so the output always satisfies `isValidLoopbackHostname`.
func hostnameSlug(_ s: String) -> String {
    var out = ""
    var lastHyphen = false
    for ch in s.lowercased() {
        if ch.isLetter || ch.isNumber {
            out.append(ch)
            lastHyphen = false
        } else if !lastHyphen {
            out.append("-")
            lastHyphen = true
        }
    }
    while out.hasPrefix("-") { out.removeFirst() }
    while out.hasSuffix("-") { out.removeLast() }
    return out
}
