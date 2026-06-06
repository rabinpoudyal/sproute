import Foundation

/// Builds the code-signing requirement string both sides use to pin each other.
/// Pins a fixed designated identifier AND the SHA-1 of the signing
/// certificate leaf — so a different cert (even from the same team) is
/// rejected. The requirement language's `H"..."` literal is a 20-byte SHA-1
/// (40 hex); a SHA-256 there fails to compile with "invalid hash length",
/// which `setCodeSigningRequirement:` surfaces as an uncaught ObjC exception.
/// The concrete identifier + hash are generated at sign time in Plan 2b-3;
/// this function just composes the canonical requirement syntax.
public func codeSigningRequirement(
    identifier: String, leafCertSHA1Hex: String
) -> String {
    "identifier \"\(identifier)\" and certificate leaf = H\"\(leafCertSHA1Hex)\""
}
