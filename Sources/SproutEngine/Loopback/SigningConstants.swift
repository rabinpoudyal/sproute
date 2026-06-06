import Foundation

/// Self-signed code-signing identity the app and helper pin each other against.
///
/// The `leafCertSHA1Hex` below is a placeholder that never matches a real
/// signature, so an unsigned dev build fails closed — the helper rejects every
/// caller and the app refuses to talk to any helper. `make certs` rewrites the
/// hash line with the real "Sprout Dev" leaf hash after minting the cert.
///
/// NOTE: do not commit a regenerated hash. It is local to whoever ran
/// `make certs`; the placeholder is what belongs in version control.
public enum SproutSigning {
    public static let appIdentifier = "com.sprout.app"
    public static let helperIdentifier = "com.sprout.helper"

    /// SHA-1 (uppercase hex, 40 chars) of the signing cert leaf, in the form
    /// the requirement language's `H"..."` literal expects. Rewritten by
    /// `make certs`.
    public static let leafCertSHA1Hex =
        "5DC023E67711AD58F8080A730EDB96807466629B"

    /// Requirement the helper applies to *callers* (must be the app).
    public static var appRequirement: String {
        codeSigningRequirement(
            identifier: appIdentifier, leafCertSHA1Hex: leafCertSHA1Hex)
    }

    /// Requirement the app applies to the *helper* connection.
    public static var helperRequirement: String {
        codeSigningRequirement(
            identifier: helperIdentifier, leafCertSHA1Hex: leafCertSHA1Hex)
    }
}
