import Foundation
import Testing

@testable import VistaraCore

@Suite
struct StoredCredentialsTests {
    private let secret = "correct horse battery staple"

    @Test func printingNeverShowsThePassword() {
        let credentials = StoredCredentials(username: "alice", domain: "CORP", password: secret)
        var dumped = ""
        dump(credentials, to: &dumped)
        for text in ["\(credentials)", String(describing: credentials), String(reflecting: credentials), dumped] {
            #expect(!text.contains(secret))
            #expect(!text.contains("alice"))
        }
        // Also not from inside a collection or an optional.
        #expect(!"\([credentials])".contains(secret))
        #expect(!String(describing: Optional(credentials)).contains(secret))
    }

    @Test func accountJoinsAndSplitsDomainAndUser() {
        #expect(StoredCredentials(username: "alice", domain: "CORP", password: "").account == "CORP\\alice")
        #expect(StoredCredentials(username: "alice", domain: "", password: "").account == "alice")
        #expect(StoredCredentials(username: "alice", password: "").account == "alice")

        let qualified = StoredCredentials.split(account: "CORP\\alice")
        #expect(qualified.username == "alice")
        #expect(qualified.domain == "CORP")
        let address = StoredCredentials.split(account: "alice@example.com")
        #expect(address.username == "alice@example.com")
        #expect(address.domain == nil)
    }
}

@Suite
struct InMemoryCredentialStoreTests {
    @Test func savesReplacesAndRemoves() throws {
        let store = InMemoryCredentialStore()
        try #expect(store.credentials(for: "a") == nil)

        try store.save(StoredCredentials(username: "alice", password: "one"), for: "a", label: "A")
        try store.save(StoredCredentials(username: "bob", password: "two"), for: "b", label: "B")
        try store.save(StoredCredentials(username: "alice", password: "three"), for: "a", label: "A")
        try #expect(store.credentials(for: "a")?.password == "three")
        try #expect(store.credentials(for: "b")?.username == "bob")

        try store.remove(for: "a")
        try store.remove(for: "a")
        try #expect(store.credentials(for: "a") == nil)
        try #expect(store.credentials(for: "b") != nil)
    }
}

/// Uses the real keychain of whoever runs the tests, under a service name of
/// its own, and removes what it adds.
@Suite(.serialized)
struct KeychainCredentialStoreTests {
    private let store = KeychainCredentialStore(servicePrefix: "io.github.sysmike.vistara.tests.")
    private let key = "core-" + UUID().uuidString

    @Test func roundTripsThroughTheKeychain() throws {
        defer { try? store.remove(for: key) }
        try #expect(store.credentials(for: key) == nil)

        let first = StoredCredentials(username: "alice", domain: "CORP", password: "pässword ✓ 1")
        try store.save(first, for: key, label: "Vistara test")
        try #expect(store.credentials(for: key) == first)

        // Saving again replaces; there is never a second item.
        let second = StoredCredentials(username: "bob", password: "two")
        try store.save(second, for: key, label: "Vistara test")
        try #expect(store.credentials(for: key) == second)

        try store.remove(for: key)
        try #expect(store.credentials(for: key) == nil)
        // Removing what is not there is not an error.
        try store.remove(for: key)
    }

    @Test func keysListOnlyThisStoresItems() throws {
        let other = KeychainCredentialStore(servicePrefix: "io.github.sysmike.vistara.tests.other.")
        defer {
            try? store.remove(for: key)
            try? other.remove(for: key)
        }
        try store.save(StoredCredentials(username: "alice", password: "one"), for: key, label: "Vistara test")
        try other.save(StoredCredentials(username: "bob", password: "two"), for: key, label: "Vistara test")
        let keys = try store.keys()
        #expect(keys.contains(key))
        // Another prefix is another store, even when it starts with this one's.
        try #expect(other.keys().contains(key))
        try store.remove(for: key)
        try #expect(!store.keys().contains(key))
    }

    @Test func oneConnectionNeverSeesAnothersPassword() throws {
        let other = key + "-other"
        defer {
            try? store.remove(for: key)
            try? store.remove(for: other)
        }
        try store.save(StoredCredentials(username: "alice", password: "one"), for: key, label: "Vistara test")
        try #expect(store.credentials(for: other) == nil)
        try store.remove(for: other)
        try #expect(store.credentials(for: key)?.password == "one")
    }
}
