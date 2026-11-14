internal import CFreeRDP
import Foundation

extension SessionHandle {
    /// What the remote computer printed since the last call, in order.
    func takePrinted() -> [RDPPrintedDocument] {
        var documents: UnsafeMutablePointer<vistara_printed_document>?
        var count = 0
        guard vistara_session_take_printed(session, &documents, &count) else { return [] }
        defer { vistara_printed_documents_free(documents, count) }
        return UnsafeBufferPointer(start: documents, count: count).map(RDPPrintedDocument.init)
    }
}

extension RDPPrintedDocument {
    fileprivate init(_ document: vistara_printed_document) {
        let content: Content =
            switch document.kind {
            case VISTARA_PRINTED_PDF:
                document.path.map { .pdf(URL(fileURLWithPath: String(cString: $0))) } ?? .notPDF
            case VISTARA_PRINTED_TOO_LARGE: .tooLarge
            default: .notPDF
            }
        self.init(content: content, size: document.size)
    }
}

/// The shim's print spool on its own, as the printer backend uses it. For tests.
final class PrintSpool {
    private let spool: OpaquePointer

    init?(folder: URL, limit: UInt64 = RDPPrintedDocument.limit) {
        guard let spool = vistara_print_spool_new(folder.path, limit) else { return nil }
        self.spool = spool
    }

    deinit {
        vistara_print_spool_free(spool)
    }

    @discardableResult
    func open(_ job: UInt32) -> Bool { vistara_print_spool_open(spool, job) }

    @discardableResult
    func write(_ job: UInt32, _ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let first = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return true }
            return vistara_print_spool_write(spool, job, first, bytes.count)
        }
    }

    func close(_ job: UInt32) { vistara_print_spool_close(spool, job) }

    func take() -> [RDPPrintedDocument] {
        var documents: UnsafeMutablePointer<vistara_printed_document>?
        var count = 0
        guard vistara_print_spool_take(spool, &documents, &count) else { return [] }
        defer { vistara_printed_documents_free(documents, count) }
        return UnsafeBufferPointer(start: documents, count: count).map(RDPPrintedDocument.init)
    }
}
