import Testing
@testable import SproutEngine

@Suite struct SproutHostsBlockTests {
    // A realistic /etc/hosts prefix that must always survive untouched.
    static let base = """
        ##
        # Host Database
        ##
        127.0.0.1\tlocalhost
        255.255.255.255\tbroadcasthost
        ::1\tlocalhost
        """

    static let withBlock =
        base + "\n" + """
            # BEGIN SPROUT (managed - do not edit)
            127.0.10.7 web.myproj.localhost vite.myproj.localhost
            127.0.10.8 web.other.localhost
            # END SPROUT
            """

    @Test func managedIPsEmptyWhenNoBlock() {
        #expect(SproutHostsBlock.managedIPs(contents: Self.base) == [])
    }

    @Test func managedIPsListsBlockIPsInOrder() {
        #expect(
            SproutHostsBlock.managedIPs(contents: Self.withBlock)
                == ["127.0.10.7", "127.0.10.8"])
    }

    @Test func foreignLinesSurviveAParseRenderRoundTrip() {
        // Removing an IP that isn't present is a no-op round-trip; user lines must persist.
        let out = SproutHostsBlock.remove(contents: Self.withBlock, ip: "127.0.10.99")
        #expect(out.contains("127.0.0.1\tlocalhost"))
        #expect(out.contains("::1\tlocalhost"))
        #expect(SproutHostsBlock.managedIPs(contents: out) == ["127.0.10.7", "127.0.10.8"])
    }
}
