import Foundation

/// Builds the exact `ifconfig` argument vector for adding/removing a loopback
/// alias. Absolute tool path plus a fixed argv (never a shell string) so the
/// IP can't inject arguments — and the IP must already have passed
/// `isValidLoopbackIP`. `active` selects `alias … up` vs `-alias`.
public enum LoopbackIfconfig {
    public static let tool = "/sbin/ifconfig"

    public static func arguments(ip: String, active: Bool) -> [String] {
        active
            ? ["lo0", "alias", ip, "up"]
            : ["lo0", "-alias", ip]
    }
}
