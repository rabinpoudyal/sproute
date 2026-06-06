import SproutEngine
import Testing

@testable import SproutApp

@Suite struct XPCReplyTests {
    @Test func nilReplyIsSuccess() throws {
        try XPCReply.check(nil)
    }

    @Test func nonNilReplyThrowsHelperRejected() {
        #expect(throws: ProvisionError.helperRejected("boom")) {
            try XPCReply.check("boom")
        }
    }
}
