import Foundation

/// Offer the remote computer one printer, "Vistara", with Windows' Microsoft
/// Print to PDF driver, and hand over what it prints (docs/DESIGN.md, Printing).
public struct RDPPrinting: Sendable, Equatable {
    /// Where documents are written while they arrive. Created if needed;
    /// the device redirection channel's notes about printers go here too.
    public var folder: URL

    public init(folder: URL) {
        self.folder = folder
    }
}

/// A document the remote computer printed.
public struct RDPPrintedDocument: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        /// A PDF in the print folder. The file is the receiver's to remove.
        case pdf(URL)
        /// Something other than a PDF, which was not kept.
        case notPDF
        /// Larger than `RDPPrintedDocument.limit`: cut off there and not kept.
        case tooLarge
    }

    /// The largest document accepted: 512 MB.
    public static let limit: UInt64 = 512 * 1024 * 1024

    public let content: Content
    /// How many bytes arrived, up to the limit.
    public let size: UInt64

    public init(content: Content, size: UInt64) {
        self.content = content
        self.size = size
    }
}

extension RDPSession {
    /// Every document the remote computer prints, in order, as it ends.
    /// Empty unless the configuration offers the printer. Ends with the session.
    public var printedDocuments: AsyncStream<RDPPrintedDocument> { printed.stream }
}

/// The printed documents of one session, from its thread to whoever listens.
final class PrintedDocuments: Sendable {
    let stream: AsyncStream<RDPPrintedDocument>
    private let continuation: AsyncStream<RDPPrintedDocument>.Continuation
    private static let log = RDPLogging.logger("Printing")

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: RDPPrintedDocument.self)
        self.stream = stream
        self.continuation = continuation
    }

    func publish(_ documents: [RDPPrintedDocument]) {
        for document in documents {
            let kind = switch document.content {
            case .pdf: "a PDF"
            case .notPDF: "not a PDF"
            case .tooLarge: "too large"
            }
            Self.log.info("Printed a document of \(document.size, privacy: .public) bytes, \(kind, privacy: .public)")
            continuation.yield(document)
        }
    }

    func finish() {
        continuation.finish()
    }
}
