import Testing
@testable import MyGitApp

@Suite struct AppVersionTests {
    @Test func comparesNumerically() {
        #expect(AppVersion("0.1.10") > AppVersion("0.1.9"))
        #expect(AppVersion("v0.2.0") > AppVersion("0.1.99"))
        #expect(AppVersion("1.0") > AppVersion("0.9.9"))
        #expect(!(AppVersion("0.1.3") > AppVersion("0.1.3")))
    }

    @Test func treatsMissingPartsAsZero() {
        #expect(AppVersion("0.1") == AppVersion("0.1.0"))
        #expect(AppVersion("v0.1.4").description == "0.1.4")
    }
}
