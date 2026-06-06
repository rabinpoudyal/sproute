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
    /// The app pins the helper against the self-signed "Sprout Dev" leaf
    /// (see `SproutSigning`). A swapped-out helper binary fails the check.
    private let helperRequirement = SproutSigning.helperRequirement

    // Temporary stub — a later task replaces this with a real XPC call to the helper.
    func listManaged() async throws -> [String] { [] }

    func setActive(ip: String, hosts: [String], active: Bool) async throws {
        let conn = NSXPCConnection(
            machServiceName: sproutHelperMachServiceName,
            options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: SproutHelperProtocol.self)
        conn.setCodeSigningRequirement(helperRequirement)
        conn.resume()
        defer { conn.invalidate() }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let once = OnceResumer(continuation)
            let proxy =
                conn.remoteObjectProxyWithErrorHandler { err in
                    once.resume(throwing: ProvisionError.helperRejected("\(err)"))
                } as? SproutHelperProtocol
            guard let proxy else {
                once.resume(throwing: ProvisionError.helperUnavailable)
                return
            }
            proxy.setActive(ip: ip, hosts: hosts, active: active) { error in
                do {
                    try XPCReply.check(error)
                    once.resume(returning: ())
                } catch {
                    once.resume(throwing: error)
                }
            }
        }
    }
}

/// Ensures a `CheckedContinuation` resumes exactly once. The XPC error handler
/// and the reply block can both fire (e.g. a connection drop after a reply);
/// the first call wins and the rest are no-ops. Lock-guarded, hence
/// `@unchecked Sendable`.
private final class OnceResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Void) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(returning: ())
        continuation = nil
    }

    func resume(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
