import Testing
@testable import Vistara

@Suite
struct LauncherInputTests {
    @Test
    func acceptsHostsWithAndWithoutPort() {
        let examples: [String: (host: String, port: UInt16)] = [
            "build01.example.com": ("build01.example.com", 3389),
            "  10.0.0.5  ": ("10.0.0.5", 3389),
            "build01:3390": ("build01", 3390),
            "fe80::1": ("fe80::1", 3389),
            "[fe80::1]": ("fe80::1", 3389),
            "[fe80::1]:3391": ("fe80::1", 3391)
        ]
        for (text, expected) in examples {
            let result = LauncherInput.hostAndPort(text)
            #expect(result?.host == expected.host, "\(text)")
            #expect(result?.port == expected.port, "\(text)")
        }
    }

    @Test(arguments: ["", "   ", ":3389", "host:", "host:0", "host:70000", "host:rdp", "[]", "[fe80::1", "[fe80::1]x"])
    func rejectsWhatIsNotAHost(text: String) {
        #expect(LauncherInput.hostAndPort(text) == nil)
    }

    @Test
    func splitsDomainFromUserName() {
        let plain = LauncherInput.userAndDomain(" alice ")
        #expect(plain.username == "alice")
        #expect(plain.domain == nil)

        let qualified = LauncherInput.userAndDomain("CORP\\alice")
        #expect(qualified.username == "alice")
        #expect(qualified.domain == "CORP")

        let address = LauncherInput.userAndDomain("alice@example.com")
        #expect(address.username == "alice@example.com")
        #expect(address.domain == nil)
    }
}
