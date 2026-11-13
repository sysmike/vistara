import SwiftUI
import UniformTypeIdentifiers
import VistaraCore

extension UTType {
    /// Microsoft's Remote Desktop connection file, declared in Info.plist.
    static let rdp = UTType(importedAs: "com.microsoft.rdp", conformingTo: .data)
}

/// One connection as an `.rdp` file, for File > Export.
struct RDPDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.rdp]

    let connection: Connection

    init(connection: Connection) {
        self.connection = connection
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        connection = try RDPFileMapping.connection(from: RDPFile(data: data), name: "")
    }

    /// UTF-16 little-endian with a byte order mark, as the Microsoft client
    /// writes it. Never a password: connections hold none.
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let wrapper = FileWrapper(regularFileWithContents: RDPFileMapping.file(from: connection).data)
        wrapper.preferredFilename = Self.fileName(for: connection)
        return wrapper
    }

    /// The connection's name as a file name.
    static func fileName(for connection: Connection) -> String {
        let name = connection.name.isEmpty ? connection.host : connection.name
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return safe + ".rdp"
    }
}
