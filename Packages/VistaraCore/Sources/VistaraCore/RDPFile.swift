import Foundation

/// The contents of a `.rdp` file: an ordered list of `key:type:value` lines.
///
/// Keys are case-insensitive and stored in lowercase. Lines that hold a
/// password are never kept.
public struct RDPFile: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case string(String)
        case integer(Int)
        /// A hex blob (type `b`), kept as text.
        case binary(String)
    }

    public struct Setting: Equatable, Sendable {
        public var key: String
        public var value: Value

        public init(key: String, value: Value) {
            self.key = key.lowercased()
            self.value = value
        }

        /// Parses one `key:type:value` line. The value may contain colons.
        public init?(line: String) {
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let text = String(parts[2])
            guard !key.isEmpty else { return nil }

            switch parts[1].lowercased() {
            case "s": self.init(key: key, value: .string(text))
            case "b": self.init(key: key, value: .binary(text))
            case "i":
                guard let number = Int(text.trimmingCharacters(in: .whitespaces)) else { return nil }
                self.init(key: key, value: .integer(number))
            default: return nil
            }
        }

        public var line: String {
            switch value {
            case .string(let text): "\(key):s:\(text)"
            case .integer(let number): "\(key):i:\(number)"
            case .binary(let hex): "\(key):b:\(hex)"
            }
        }

        var holdsPassword: Bool { key.contains("password") }
    }

    public enum ParseError: Error, Equatable {
        case unreadableEncoding
    }

    public var settings: [Setting] = []
    /// Lines that are not valid `key:type:value`, as found.
    public var skippedLines: [String] = []
    /// True when the source had a password line. The password was discarded.
    public var droppedPassword = false

    public init(settings: [Setting] = []) {
        self.settings = settings.filter { !$0.holdsPassword }
    }

    public init(text: String) {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let setting = Setting(line: line) else {
                skippedLines.append(line)
                continue
            }
            if setting.holdsPassword {
                droppedPassword = true
            } else {
                settings.append(setting)
            }
        }
    }

    /// Reads UTF-16 or UTF-8 with a byte order mark (the Microsoft client
    /// writes UTF-16 little-endian), or UTF-8 without one.
    public init(data: Data) throws {
        let bytes = [UInt8](data.prefix(3))
        let text: String?
        if bytes.starts(with: [0xFF, 0xFE]) {
            text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            text = String(data: data.dropFirst(3), encoding: .utf8)
        } else if data.contains(0) {
            text = String(data: data, encoding: .utf16LittleEndian)
        } else {
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
        }
        guard let text else { throw ParseError.unreadableEncoding }
        self.init(text: text)
    }

    public subscript(key: String) -> Value? {
        settings.last { $0.key == key.lowercased() }?.value
    }

    public func string(_ key: String) -> String? {
        if case .string(let text)? = self[key] { text } else { nil }
    }

    public func integer(_ key: String) -> Int? {
        if case .integer(let number)? = self[key] { number } else { nil }
    }

    /// The file as text with Windows line endings.
    public var text: String {
        settings.map { $0.line + "\r\n" }.joined()
    }

    /// The file as the Microsoft client writes it: UTF-16 little-endian with
    /// a byte order mark.
    public var data: Data {
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian) ?? Data())
        return data
    }
}
