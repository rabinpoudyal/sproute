#import "CSproutXPC.h"

// NSXPCConnection exposes `auditToken` but does not declare it publicly.
// Forward-declare it so the compiler lets us read it.
@interface NSXPCConnection (SproutAuditToken)
@property (nonatomic, readonly) audit_token_t auditToken;
@end

audit_token_t SproutConnectionAuditToken(NSXPCConnection *connection) {
    return connection.auditToken;
}
