import Foundation
import VistaraCore

/// What an import did, said above the list (not in an alert).
struct ImportReport: Equatable {
    /// Names of the connections added.
    var imported: [String] = []
    /// Files whose password line was dropped: Vistara keeps passwords only in
    /// the Keychain.
    var droppedPasswords: [String] = []
    /// Lines that were not settings, in all files.
    var skippedLines = 0
    /// Files that could not be imported, with why.
    var failures: [String] = []

    var isEmpty: Bool { imported.isEmpty && failures.isEmpty }

    /// What the notice says, one sentence per finding.
    var sentences: [String] {
        var sentences: [String] = []
        switch imported.count {
        case 0: break
        case 1: sentences.append("Imported “\(imported[0])”.")
        default: sentences.append("Imported \(imported.count) connections.")
        }
        if !droppedPasswords.isEmpty {
            let which = droppedPasswords.count == 1 ? "“\(droppedPasswords[0])”" : "\(droppedPasswords.count) files"
            sentences.append("The password in \(which) was not imported; Vistara asks for it when connecting.")
        }
        if skippedLines == 1 {
            sentences.append("1 line that isn’t a setting was skipped.")
        } else if skippedLines > 1 {
            sentences.append("\(skippedLines) lines that aren’t settings were skipped.")
        }
        return sentences + failures
    }
}

extension LibraryModel {
    /// Adds a connection for each `.rdp` file, named after the file, selects
    /// them, and reports what happened.
    @discardableResult
    func importRDPFiles(_ urls: [URL]) async -> ImportReport {
        guard canChange else { return ImportReport() }
        var report = ImportReport()
        var added: [Connection.ID] = []
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            let isScoped = url.startAccessingSecurityScopedResource()
            defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let file = try RDPFile(data: Data(contentsOf: url))
                let connection = try RDPFileMapping.connection(from: file, name: name)
                await save(connection)
                added.append(connection.id)
                report.imported.append(name)
                if file.droppedPassword { report.droppedPasswords.append(name) }
                report.skippedLines += file.skippedLines.count
            } catch RDPFileMapping.ImportError.missingAddress {
                report.failures.append("“\(url.lastPathComponent)” names no computer and wasn’t imported.")
            } catch {
                report.failures.append("“\(url.lastPathComponent)” couldn’t be read and wasn’t imported.")
            }
        }
        if !added.isEmpty {
            selection = .all
            selectedIDs = Set(added)
        }
        importReport = report.isEmpty ? nil : report
        return report
    }

    /// Imports now, or as soon as the library has loaded.
    func importWhenLoaded(_ urls: [URL]) async {
        guard loadState == .loaded else {
            pendingImports += urls
            return
        }
        await importRDPFiles(urls)
    }

    /// The selected connections as documents for File > Export.
    var selectedDocuments: [RDPDocument] {
        library.connections.filter { selectedIDs.contains($0.id) }.map(RDPDocument.init)
    }
}
