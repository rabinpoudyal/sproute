import Foundation

/// Builds the code-signing requirement string both sides use to pin each other.
/// Pins a fixed designated identifier AND the SHA-256 of the signing
/// certificate leaf — so a different cert (even from the same team) is
/// rejected. The concrete identifier + hash are generated at sign time in
/// Plan 2b-3; this function just composes the canonical requirement syntax.
public func codeSigningRequirement(
    identifier: String, leafCertSHA256Hex: String
) -> String {
    "identifier \"\(identifier)\" and certificate leaf = H\"\(leafCertSHA256Hex)\""
}
