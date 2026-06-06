import Foundation

/// Mach service name the privileged helper registers and the app connects to.
/// Must match the `MachServices` key in the helper's launchd plist (Plan 2b-3).
public let sproutHelperMachServiceName = "com.sprout.helper.xpc"

/// The narrow XPC contract between the unprivileged app and the root helper.
/// Three calls only — every one is validated helper-side before any side
/// effect. `@objc` with reply blocks because `NSXPCConnection` requires an
/// Objective-C protocol using completion-handler methods (no async/throws
/// across the boundary).
@objc public protocol SproutHelperProtocol {
    /// Install (`active == true`) or remove (`false`) the `lo0` alias for `ip`
    /// plus its `/etc/hosts` block. `reply` carries `nil` on success or a
    /// human-readable error string on rejection/failure.
    func setActive(
        ip: String, hosts: [String], active: Bool,
        reply: @escaping (String?) -> Void)

    /// Liveness probe: returns the helper's version so the app can detect a
    /// stale installed helper after an app upgrade.
    func ping(reply: @escaping (String) -> Void)

    /// The loopback IPs the helper currently manages in `/etc/hosts`, for the
    /// app's reconcile/reaper. Empty when nothing is provisioned.
    func listManaged(reply: @escaping ([String]) -> Void)
}
