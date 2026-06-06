#import <Foundation/Foundation.h>
#import <bsm/libbsm.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns the audit token of the process on the other end of `connection`.
/// Reads `NSXPCConnection`'s `auditToken` property (declared via a category
/// below); the token is what `SecCodeCopyGuestWithAttributes` needs to pin the
/// caller's code signature.
audit_token_t SproutConnectionAuditToken(NSXPCConnection *connection);

NS_ASSUME_NONNULL_END
