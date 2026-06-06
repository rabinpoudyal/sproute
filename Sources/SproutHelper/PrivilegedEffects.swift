import Foundation
import SproutEngine

/// The only code in the system that mutates `lo0` or `/etc/hosts`. Runs as root
/// inside the helper. Validates every request again (defense in depth — the app
/// already validated, but the helper trusts nothing) before any side effect.
enum PrivilegedEffects {
    static let hostsPath = "/etc/hosts"

    /// Apply one provisioning request. Ordering matters: bring the alias up
    /// before publishing the hostname, and remove the hostname before tearing
    /// the alias down, so a published hostname never resolves to an un-aliased
    /// IP.
    static func apply(ip: String, hosts: [String], active: Bool) throws {
        try validateLoopbackRequest(ip: ip, hosts: active ? hosts : [])
        if active {
            try runIfconfig(ip: ip, active: true)
            try editHosts { SproutHostsBlock.upsert(contents: $0, ip: ip, hosts: hosts) }
        } else {
            try editHosts { SproutHostsBlock.remove(contents: $0, ip: ip) }
            try runIfconfig(ip: ip, active: false)
        }
    }

    static func managedIPs() -> [String] {
        let contents = (try? String(contentsOfFile: hostsPath, encoding: .utf8)) ?? ""
        return SproutHostsBlock.managedIPs(contents: contents)
    }

    private static func runIfconfig(ip: String, active: Bool) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: LoopbackIfconfig.tool)
        proc.arguments = LoopbackIfconfig.arguments(ip: ip, active: active)
        let errPipe = Pipe()
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            throw ProvisionError.ifconfigFailed(String(describing: error))
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg =
                String(
                    data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8) ?? ""
            throw ProvisionError.ifconfigFailed(
                msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func editHosts(_ transform: (String) -> String) throws {
        let current: String
        do {
            current = try String(contentsOfFile: hostsPath, encoding: .utf8)
        } catch {
            // Fail closed: never overwrite /etc/hosts based on a failed read,
            // which would discard every non-managed entry in the file.
            throw ProvisionError.hostsWriteFailed("read failed: \(error)")
        }
        let updated = transform(current)
        guard updated != current else { return }
        do {
            try updated.write(toFile: hostsPath, atomically: true, encoding: .utf8)
        } catch {
            throw ProvisionError.hostsWriteFailed(String(describing: error))
        }
    }
}
