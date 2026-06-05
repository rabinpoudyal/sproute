import Testing
@testable import SproutEngine

@Suite struct LoopbackValidationTests {
    @Test func acceptsInRangeLoopbackIPs() {
        #expect(isValidLoopbackIP("127.0.10.1"))
        #expect(isValidLoopbackIP("127.0.10.42"))
        #expect(isValidLoopbackIP("127.0.10.254"))
    }

    @Test func rejectsOutOfRangeOctet() {
        #expect(!isValidLoopbackIP("127.0.10.0"))  // .0 network address
        #expect(!isValidLoopbackIP("127.0.10.255"))  // .255 broadcast
        #expect(!isValidLoopbackIP("127.0.10.256"))
    }

    @Test func rejectsWrongPrefix() {
        #expect(!isValidLoopbackIP("127.0.11.1"))
        #expect(!isValidLoopbackIP("127.0.0.1"))
        #expect(!isValidLoopbackIP("10.0.0.1"))
    }

    @Test func rejectsMalformed() {
        #expect(!isValidLoopbackIP("127.0.10.01"))  // non-canonical leading zero
        #expect(!isValidLoopbackIP("127.0.10.1 "))  // trailing space
        #expect(!isValidLoopbackIP("127.0.10."))
        #expect(!isValidLoopbackIP("127.0.10.1.5"))
        #expect(!isValidLoopbackIP(""))
    }
}
