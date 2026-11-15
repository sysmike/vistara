import Foundation

/// A program to open in place of the desktop, in `.rdp` files as the
/// Microsoft client writes them (docs/DESIGN.md, RemoteApp):
/// `remoteapplicationmode`, `remoteapplicationprogram`,
/// `remoteapplicationname`, and `remoteapplicationcmdline`. The file's other
/// RemoteApp lines, such as its icon's path, are kept as written.
extension RDPFileMapping {
    static let programKeys: Set<String> = [
        "remoteapplicationmode", "remoteapplicationprogram", "remoteapplicationname", "remoteapplicationcmdline"
    ]

    private static func programPath(in file: RDPFile) -> String? {
        guard let path = file.string("remoteapplicationprogram")?.trimmingCharacters(in: .whitespaces),
            !path.isEmpty
        else { return nil }
        return path
    }

    /// Whether the file asks for a program without naming one. It opens the
    /// desktop, and the import notice says why.
    public static func asksForAProgramWithoutOne(_ file: RDPFile) -> Bool {
        file.integer("remoteapplicationmode") == 1 && programPath(in: file) == nil
    }

    /// The program, and the name the file gives it, which replaces the one
    /// from the file's name.
    static func applyProgram(of file: RDPFile, to connection: inout Connection) {
        var program = Connection.Program()
        program.path = programPath(in: file) ?? ""
        program.arguments = file.string("remoteapplicationcmdline") ?? ""
        program.opens = file.integer("remoteapplicationmode") == 1 && !program.path.isEmpty ? .program : .desktop
        connection.program = program
        if program.isUsed, let name = file.string("remoteapplicationname")?.trimmingCharacters(in: .whitespaces),
            !name.isEmpty {
            connection.name = name
        }
    }

    /// Nothing for a connection that opens the desktop.
    static func programSettings(of connection: Connection) -> [RDPFile.Setting] {
        let program = connection.program
        guard program.isUsed else { return [] }
        var settings: [RDPFile.Setting] = [
            .init(key: "remoteapplicationmode", value: .integer(1)),
            .init(key: "remoteapplicationprogram", value: .string(program.path)),
            .init(key: "remoteapplicationname", value: .string(connection.name))
        ]
        if !program.arguments.isEmpty {
            settings.append(.init(key: "remoteapplicationcmdline", value: .string(program.arguments)))
        }
        return settings
    }
}
