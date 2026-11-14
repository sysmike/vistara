import Foundation
import Observation
import RDPKit

/// What a session's remote computer printed, waiting to be shown in turn
/// (docs/DESIGN.md, Printing). The session window shows the first item.
@MainActor
@Observable
final class PrintQueue {
    enum Content: Equatable {
        /// A PDF to show in the print panel.
        case document(URL)
        /// Something that can't be printed: not a PDF, or too large.
        case refused(tooLarge: Bool)
    }

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let content: Content
    }

    /// Where every session's documents go, each connection in a folder of its own.
    static let parentFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Vistara Printing", isDirectory: true)

    /// The item to show now, until it is finished.
    var next: Item? { items.first }
    private var items: [Item] = []
    @ObservationIgnored private(set) var folder: URL?
    @ObservationIgnored private var listener: Task<Void, Never>?

    /// A new folder for a connection's documents, as RDPKit takes it.
    func makePrinting() -> RDPPrinting {
        end()
        let folder = Self.parentFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
        return RDPPrinting(folder: folder)
    }

    /// Takes what the session prints, until it ends.
    func listen(to documents: AsyncStream<RDPPrintedDocument>) {
        listener?.cancel()
        listener = Task { [weak self] in
            for await document in documents { self?.add(document) }
        }
    }

    func add(_ document: RDPPrintedDocument) {
        switch document.content {
        case .pdf(let url): items.append(Item(content: .document(url)))
        case .notPDF: items.append(Item(content: .refused(tooLarge: false)))
        case .tooLarge: items.append(Item(content: .refused(tooLarge: true)))
        }
    }

    /// The item was printed, saved, cancelled, or acknowledged: its file goes,
    /// and the next one is shown.
    func finish(_ item: Item) {
        if case .document(let url) = item.content {
            try? FileManager.default.removeItem(at: url)
        }
        items.removeAll { $0.id == item.id }
    }

    /// The connection ended: nothing waits any more, and its documents are
    /// removed. One already in the print panel stays there, read in memory.
    func end() {
        listener?.cancel()
        listener = nil
        items.removeAll()
        if let folder {
            try? FileManager.default.removeItem(at: folder)
        }
        folder = nil
    }
}

/// What the session window says about a document it can't print
/// (docs/DESIGN.md, Errors).
enum PrintRefusal {
    static func title(name: String) -> String {
        "A document from “\(name)” can’t be printed"
    }

    static func explanation(tooLarge: Bool) -> String {
        tooLarge
            ? "It’s larger than 512 MB, the most Vistara takes."
            : "Vistara prints only PDF documents. Print it again with the printer “Vistara”, "
                + "without changing its driver."
    }
}
