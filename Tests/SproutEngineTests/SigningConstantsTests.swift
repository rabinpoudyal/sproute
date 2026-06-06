import Testing

@testable import SproutEngine

@Suite struct SigningConstantsTests {
    @Test func appRequirementComposesIdentifierAndLeafHash() {
        let expected = codeSigningRequirement(
            identifier: SproutSigning.appIdentifier,
            leafCertSHA256Hex: SproutSigning.leafCertSHA256Hex)
        #expect(SproutSigning.appRequirement == expected)
    }

    @Test func helperRequirementComposesIdentifierAndLeafHash() {
        let expected = codeSigningRequirement(
            identifier: SproutSigning.helperIdentifier,
            leafCertSHA256Hex: SproutSigning.leafCertSHA256Hex)
        #expect(SproutSigning.helperRequirement == expected)
    }

    @Test func identifiersAreStable() {
        #expect(SproutSigning.appIdentifier == "com.sprout.app")
        #expect(SproutSigning.helperIdentifier == "com.sprout.helper")
    }
}
