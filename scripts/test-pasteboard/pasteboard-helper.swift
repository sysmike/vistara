// Stands in for the Finder in the file clipboard probes (#134): an app
// outside the sandbox that copies files to the general pasteboard and pastes
// files from it. CI runs it for the sandboxed app tests, which ask
// through files in their container (see App/Tests/FileClipboardProbeTests.swift).
//
// Usage:
//   pasteboard-helper copy <directory>       Makes a file and a folder with a
//                                            file in <directory>, and copies the
//                                            two to the pasteboard.
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
    // Next to them, never copied: whether the app can read here at all.
    let control = directory.appendingPathComponent("Control.txt")
    do {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Not copied\n".utf8).write(to: control)
        try Data("Quarterly report\n".utf8).write(to: file)
        try Data("Inside the folder\n".utf8).write(to: folder.appendingPathComponent("Inner.txt"))
    } catch {
        reply(["error": "\(error)"])
    }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let written = pasteboard.writeObjects([file as NSURL, folder as NSURL])
    reply(["written": written, "file": file.path, "folder": folder.path, "control": control.path])
}

func readURLs() -> Never {
    let started = Date()
    let types = NSPasteboard.general.types?.map(\.rawValue) ?? []
    let urls = NSPasteboard.general.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
    ) as? [URL] ?? []
    let files: [[String: Any]] = urls.map { url in
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        let quarantined = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) > 0
        return ["name": url.lastPathComponent, "size": size?.intValue ?? -1, "quarantined": quarantined]
    }
    reply(["files": files, "seconds": Date().timeIntervalSince(started), "types": types])
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { reply(["error": "usage: pasteboard-helper copy|read-urls <directory>"]) }
let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
switch arguments[1] {
case "copy": copy(into: directory)
case "read-urls": readURLs()
default: reply(["error": "unknown command \(arguments[1])"])
}
