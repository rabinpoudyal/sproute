import Foundation
import SproutEngine

/// Maps the helper's `String?` reply to a throwing result. `nil` means success;
/// any string is the helper's human-readable rejection/failure reason, surfaced
/// as `ProvisionError.helperRejected`.
enum XPCReply {
    static func check(_ error: String?) throws {
        if let error {
            throw ProvisionError.helperRejected(error)
        }
    }
}
