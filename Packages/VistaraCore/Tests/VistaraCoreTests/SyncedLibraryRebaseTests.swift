import Foundation
import Testing

@testable import VistaraCore

/// Saving on top of what other Macs changed meanwhile, choosing the folder,
/// and noticing it changed: what the app's library needs (#149).
@Suite
struct SyncedLibraryRebaseTests {
    /// Where a connection is: a library's order follows identifiers, which are random.
    private func index(of connection: Connection, in library: Library) throws -> Int {
        try #require(library.connections.firstIndex { $0.id == connection.id })
    }

    private func names(_ library: Library) -> [String] { library.connections.map(\.name).sorted() }

    @Test func aSaveBasedOnAnOlderLibraryKeepsWhatAnotherMacChangedMeanwhile() async throws {
        let macs = try TwoMacs()
        defer { macs.cleanUp() }
        let build = Connection(name: "Build Server", host: "build01")
        let jump = Connection(name: "Jump Host", host: "jump01")
        _ = try await macs.first.save(Library(connections: [build, jump]))
        // What the second Mac's window shows, and keeps changing.
        let base = try await macs.second.sync().library

        macs.clock.advance()
        var mine = try await macs.first.sync().library
        mine.connections[try index(of: build, in: mine)].name = "Build Server 2"
        _ = try await macs.first.save(mine)
        _ = try await macs.second.sync()

        // The second Mac renames the other connection and uses the first one,
        // both on top of what it showed before the first Mac's change.
        macs.clock.advance()
        var changed = base
        changed.connections[try index(of: jump, in: changed)].name = "Jump Host 2"
        changed.connections[try index(of: build, in: changed)].lastConnectedAt = macs.clock.now()
        let theirs = try await macs.second.save(changed, basedOn: base).library

        #expect(names(theirs) == ["Build Server 2", "Jump Host 2"])
        #expect(theirs.connections[try index(of: build, in: theirs)].lastConnectedAt == macs.clock.now())
        let both = try await macs.first.sync().library
        #expect(names(both) == ["Build Server 2", "Jump Host 2"])
        #expect(both.connections[try index(of: build, in: both)].lastConnectedAt == nil)
    }

    @Test func aSaveBasedOnAnOlderLibraryKeepsWhatAnotherMacAddedAndDeleted() async throws {
        let macs = try TwoMacs()
        defer { macs.cleanUp() }
        let build = Connection(name: "Build Server", host: "build01")
        let jump = Connection(name: "Jump Host", host: "jump01")
        _ = try await macs.first.save(Library(connections: [build, jump]))
        let base = try await macs.second.sync().library

        macs.clock.advance()
        let added = Connection(name: "Lab", host: "lab01")
        _ = try await macs.first.save(Library(connections: [build, added]))
        _ = try await macs.second.sync()

        // A per-Mac change to the deleted one doesn't bring it back; an edit would.
        macs.clock.advance()
        var changed = base
        changed.connections[try index(of: jump, in: changed)].lastConnectedAt = macs.clock.now()
        let theirs = try await macs.second.save(changed, basedOn: base).library
        #expect(names(theirs) == ["Build Server", "Lab"])

        var edited = changed
        edited.connections[try index(of: jump, in: edited)].name = "Jump Host 2"
        let back = try await macs.second.save(edited, basedOn: changed).library
        #expect(names(back) == ["Build Server", "Jump Host 2", "Lab"])
    }

    @Test func joiningKeepsWhatTheFolderMarksDeleted() async throws {
        let macs = try TwoMacs()
        defer { macs.cleanUp() }
        let build = Connection(name: "Build Server", host: "build01")
        _ = try await macs.first.save(Library(connections: [build]))
        _ = try await macs.second.sync()
        macs.clock.advance()
        _ = try await macs.first.save(Library())

        // The second Mac had gone back to On This Mac before the deletion, and chooses the folder again.
        let second = macs.store("Second Mac")
        _ = try await second.load()
        macs.clock.advance()
        let joined = try await second.join()

        #expect(names(joined.library) == ["Build Server"])
        #expect(try await names(macs.first.sync().library) == ["Build Server"])
    }

    @Test func aChangeInTheFolderIsNoticed() async throws {
        let macs = try TwoMacs()
        defer { macs.cleanUp() }
        _ = try await macs.first.load()
        #expect(await macs.first.needsSync())
        _ = try await macs.first.sync()
        #expect(await !macs.first.needsSync())

        _ = try await macs.second.save(Library(connections: [Connection(name: "Build", host: "build01")]))
        #expect(await macs.first.needsSync())
        _ = try await macs.first.sync()
        #expect(await !macs.first.needsSync())
    }

    @Test func aStampFinerThanTheFilesKeepIsNotWrittenAgain() async throws {
        let macs = try TwoMacs()
        defer { macs.cleanUp() }
        let store = SyncedLibraryStore(
            localDirectory: macs.root.appendingPathComponent("Third Mac", isDirectory: true), folder: macs.shared,
            now: { Date(timeIntervalSince1970: 1_800_000_000.75) }
        )
        let build = Connection(name: "Build", host: "build01")
        let file = macs.file("connections", build.id)
        // A new URL each time: one caches what it read.
        let modified = {
            (try? URL(fileURLWithPath: file.path).resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }
        _ = try await store.load()
        _ = try await store.save(Library(connections: [build]))
        let written = modified()

        _ = try await store.sync()
        #expect(await !store.needsSync())
        #expect(written != nil)
        #expect(modified() == written)
    }

    @Test func aChangeWithinTheSameSecondIsStillTheLaterOne() async throws {
        let macs = try TwoMacs()
        defer { macs.cleanUp() }
        let build = Connection(name: "Build Server", host: "build01")
        _ = try await macs.first.save(Library(connections: [build]))
        var theirs = try await macs.second.sync().library

        theirs.connections[0].name = "Build Server 2"
        theirs = try await macs.second.save(theirs).library

        #expect(names(theirs) == ["Build Server 2"])
        #expect(try await names(macs.first.sync().library) == ["Build Server 2"])
    }
}
