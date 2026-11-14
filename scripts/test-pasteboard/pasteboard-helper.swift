// Stands in for the Finder in the file clipboard probes (#134): an app
// outside the sandbox that copies files to the general pasteboard and pastes
// promised files from it. CI runs it for the sandboxed app tests, which ask
// through files in their container (see App/Tests/FileClipboardProbeTests.swift).
//
// Usage:
//   pasteboard-helper copy <directory>       Makes a file and a folder with a
//                                            file in <directory>, and copies the
//                                            two to the pasteboard.
//   pasteboard-helper receive <directory>    Pastes the promised files on the
//                                            pasteboard into <directory>.
//   pasteboard-helper read-urls <directory>  Reads the file URLs on the
//                                            pasteboard, as a paste in the Finder
//                                            asks for them, and checks each file.
// Prints one line of JSON with what happened.

import AppKit
import Foundation

func reply(_ object: [String: Any]) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(0)
}

func copy(into directory: URL) -> Never {
    let fileManager = FileManager.default
    let file = directory.appendingPathComponent("Report.txt")
    let folder = directory.appendingPathComponent("Folder", isDirectory: true)
    do {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Quarterly report\n".utf8).write(to: file)
        try Data("Inside the folder\n".utf8).write(to: folder.appendingPathComponent("Inner.txt"))
    } catch {
        reply(["error": "\(error)"])
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let written = pasteboard.writeObjects([file as NSURL, folder as NSURL])
    reply(["written": written, "file": file.path, "folder": folder.path])
}

func receive(into directory: URL) -> Never {
    let types = NSPasteboard.general.types?.map(\.rawValue) ?? []
    let receivers = NSPasteboard.general.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]
    guard let receivers, !receivers.isEmpty else { reply(["error": "no file promise on the pasteboard", "types": types]) }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let queue = OperationQueue()
    var results: [[String: Any]] = []
    var pending = receivers.count
    let started = Date()
    for receiver in receivers {
        receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: queue) { url, error in
            var result: [String: Any] = ["name": url.lastPathComponent]
            if let error { result["error"] = "\(error)" }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            result["size"] = (attributes?[.size] as? NSNumber)?.intValue ?? -1
            result["quarantined"] = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) > 0
            DispatchQueue.main.async {
                results.append(result)
                pending -= 1
            }
        }
    }
    let deadline = Date().addingTimeInterval(30)
    while pending > 0, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    reply([
        "files": results, "seconds": Date().timeIntervalSince(started), "timedOut": pending > 0, "types": types,
        "promisedTypes": receivers.flatMap(\.fileTypes)
    ])
}

func readURLs() -> Never {
    let started = Date()
    let types = NSPasteboard.general.types?.map(\.rawValue) ?? []
    let urls = NSPasteboard.general.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
    ) as? [URL] ?? []
    let files: [[String: Any]] = urls.map { url in
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        return ["name": url.lastPathComponent, "size": size?.intValue ?? -1]
    }
    reply(["files": files, "seconds": Date().timeIntervalSince(started), "types": types])
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { reply(["error": "usage: pasteboard-helper copy|receive <directory>"]) }
let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
switch arguments[1] {
case "copy": copy(into: directory)
case "receive": receive(into: directory)
case "read-urls": readURLs()
default: reply(["error": "unknown command \(arguments[1])"])
}
