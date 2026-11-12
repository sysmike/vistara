import Foundation
import Testing

@testable import RDPKit

@Suite
struct LogRedactorTests {
    private func redactor() -> LogRedactor {
        let redactor = LogRedactor()
        redactor.add("build01.example.com", as: .host)
        redactor.add("alice", as: .user)
        redactor.add("CORP", as: .user)
        redactor.add("correct horse battery", as: .secret)
        return redactor
    }

    @Test func hostUserAndDomainAreReplaced() {
        let line = redactor().redact("NLA for CORP\\alice on build01.example.com:3389 failed")
        #expect(line == "NLA for <user>\\<user> on <host>:3389 failed")
    }

    @Test func caseDoesNotMatter() {
        #expect(redactor().redact("BUILD01.Example.COM said hello to Alice") == "<host> said hello to <user>")
    }

    @Test func passwordsAreReplacedWherever() {
        #expect(redactor().redact("password=correct horse battery;") == "password=<redacted>;")
    }

    @Test func ipAddressesAreReplacedWithoutBeingRegistered() {
        let line = LogRedactor().redact("connect to 10.20.30.40:3389 failed; fe80::1%en0 and 2001:db8::7 too")
        #expect(line == "connect to <address>:3389 failed; <address> and <address> too")
    }

    @Test func longerValuesWinOverValuesInsideThem() {
        let redactor = LogRedactor()
        redactor.add("ann", as: .user)
        redactor.add("annex.example.com", as: .host)
        #expect(redactor.redact("annex.example.com, ann") == "<host>, <user>")
    }

    @Test func veryShortValuesAreNotMatched() {
        let redactor = LogRedactor()
        redactor.add("ab", as: .user)
        #expect(redactor.redact("about a table") == "about a table")
    }

    @Test func aRemovedValueIsNoLongerReplaced() {
        let redactor = redactor()
        redactor.remove("correct horse battery")
        #expect(redactor.redact("correct horse battery") == "correct horse battery")
        #expect(redactor.redact("alice") == "<user>")
    }

    @Test func replacementsAreCounted() {
        let redactor = redactor()
        _ = redactor.redact("alice at build01.example.com from 10.0.0.1")
        #expect(redactor.redactionCount == 3)
        _ = redactor.redact("nothing to see")
        #expect(redactor.redactionCount == 3)
    }

    @Test func aPlaceholderIsNeverMatchedAgain() {
        let redactor = LogRedactor()
        redactor.add("host", as: .user)
        #expect(redactor.redact("host") == "<user>")
    }
}
