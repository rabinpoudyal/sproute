import CSproutXPC
import Foundation
import Security
import SproutEngine

/// Listener delegate + protocol implementation for the root daemon. Accepts a
/// connection only if the caller's code signature satisfies `appRequirement`,
/// then services the three contract methods. The requirement is a placeholder
/// until Plan 2b-3 generates the real identifier + leaf hash at sign time.
final class HelperService: NSObject, NSXPCListenerDelegate, SproutHelperProtocol {
    static let version = "1"

    private let appRequirement: String

    init(appRequirement: String) {
        self.appRequirement = appRequirement
    }

    // MARK: NSXPCListenerDelegate

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection conn: NSXPCConnection
    ) -> Bool {
        guard callerSatisfiesRequirement(conn) else { return false }
        conn.exportedInterface = NSXPCInterface(with: SproutHelperProtocol.self)
        conn.exportedObject = self
        conn.resume()
        return true
    }

    // MARK: SproutHelperProtocol

    func setActive(
        ip: String, hosts: [String], active: Bool,
        reply: @escaping (String?) -> Void
    ) {
        do {
            try PrivilegedEffects.apply(ip: ip, hosts: hosts, active: active)
            reply(nil)
        } catch let e as ProvisionError {
            reply(describe(e))
        } catch {
            reply(String(describing: error))
        }
    }

    func ping(reply: @escaping (String) -> Void) { reply(Self.version) }

    func listManaged(reply: @escaping ([String]) -> Void) {
        reply(PrivilegedEffects.managedIPs())
    }

    // MARK: Caller pinning

    /// True iff the connecting process's code signature satisfies
    /// `appRequirement`. Uses the connection's audit token (not PID, which is
    /// reuse/TOCTOU-prone) to identify the caller.
    private func callerSatisfiesRequirement(_ conn: NSXPCConnection) -> Bool {
        var token = SproutConnectionAuditToken(conn)
        let tokenData = Data(
            bytes: &token, count: MemoryLayout.size(ofValue: token))
        let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        guard
            SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
            let guest = code
        else { return false }
        var req: SecRequirement?
        guard
            SecRequirementCreateWithString(appRequirement as CFString, [], &req)
                == errSecSuccess,
            let requirement = req
        else { return false }
        return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
    }

    private func describe(_ e: ProvisionError) -> String {
        switch e {
        case .helperUnavailable: return "helper unavailable"
        case .helperRejected(let m): return "rejected: \(m)"
        case .ifconfigFailed(let m): return "ifconfig failed: \(m)"
        case .hostsWriteFailed(let m): return "hosts write failed: \(m)"
        }
    }
}
