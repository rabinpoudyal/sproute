import Foundation

/// Reference-counts running processes per branch and drives the provisioner on
/// the transitions that matter: install the alias + hosts on the first start
/// (0 -> 1), remove them on the last stop (1 -> 0).
///
/// `activate` provisions BEFORE incrementing, so a failed provision leaves the
/// count untouched and the caller can abort the start. `deactivate` never
/// throws — a failed release is logged-and-forgotten (stale state is reaped by
/// the launch sweep in the follow-up plan).
public actor LoopbackCoordinator {
    private let provisioner: LoopbackProvisioner
    private var counts: [String: Int] = [:]

    public init(provisioner: LoopbackProvisioner) {
        self.provisioner = provisioner
    }

    public func activate(branch: String, ip: String, hosts: [String]) async throws {
        let current = counts[branch] ?? 0
        if current == 0 {
            try await provisioner.setActive(ip: ip, hosts: hosts, active: true)
        }
        counts[branch] = current + 1
    }

    public func deactivate(branch: String, ip: String, hosts: [String]) async {
        let current = counts[branch] ?? 0
        guard current > 0 else { return }
        let next = current - 1
        counts[branch] = next
        if next == 0 {
            counts[branch] = nil
            try? await provisioner.setActive(ip: ip, hosts: hosts, active: false)
        }
    }
}
