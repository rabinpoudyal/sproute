import Foundation
import Security
import SproutEngine

/// `LoopbackProvisioner` that forwards `setActive` to the root helper over a
/// code-signature-pinned `NSXPCConnection`. The app pins the helper
/// (`setCodeSigningRequirement`) so a swapped-out helper binary can't service
/// requests; the helper independently pins the app. A fresh connection per call
/// keeps the seam simple — provisioning is rare (start/stop of the first/last
/// process per branch).
final class XPCProvisioner: LoopbackProvisioner, @unchecked Sendable {
    /// Placeholder helper requirement until Plan 2b-3 generates the real
    /// identifier + leaf hash. Mirrors the helper's placeholder so dev builds
    /// fail closed.
    private let helperRequirement = "identifier \"com.sprout.helper.PLACEHOLDER\""

    func setActive(ip: String, hosts: [String], active: Bool) async throws {
        let conn = NSXPCConnection(
            machServiceName: sproutHelperMachServiceName,
            options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: SproutHelperProtocol.self)
        if #available(macOS 13.0, *) {
            conn.setCodeSigningRequirement(helperRequirement)
        }
        conn.resume()
        defer { conn.invalidate() }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let proxy =
                conn.remoteObjectProxyWithErrorHandler { err in
                    continuation.resume(throwing: ProvisionError.helperRejected("\(err)"))
                } as? SproutHelperProtocol
            guard let proxy else {
                continuation.resume(throwing: ProvisionError.helperUnavailable)
                return
            }
            proxy.setActive(ip: ip, hosts: hosts, active: active) { error in
                do {
                    try XPCReply.check(error)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
