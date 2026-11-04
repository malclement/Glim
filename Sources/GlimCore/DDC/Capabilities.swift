import Foundation

/// A parsed MCCS capabilities string, such as
/// `(prot(monitor)type(LCD)model(HP E27m G4)cmds(01 02 03)vcp(10 12 60(0F 11 13)))`.
///
/// A display's self-description is a hint, not the truth: the HP E27m G4 lists
/// codes that refuse a plain Get and omits codes that answer one. Glim
/// confirms a control by reading it before showing it.
public struct MonitorCapabilities: Equatable, Sendable {
    /// One VCP code and the values listed for it. Values can nest, as in HP's
    /// sub-coded vendor controls: `E1(04(00 01) 0F(00 01))`.
    public struct Entry: Equatable, Sendable {
        public var code: UInt8
        public var values: [Entry]

        public init(code: UInt8, values: [Entry] = []) {
            self.code = code
            self.values = values
        }
    }

    public var model: String?
    public var displayType: String?
    public var mccsVersion: String?
    public var commands: [UInt8]
    public var vcp: [Entry]

    public init(model: String? = nil, displayType: String? = nil, mccsVersion: String? = nil,
                commands: [UInt8] = [], vcp: [Entry] = []) {
        self.model = model
        self.displayType = displayType
        self.mccsVersion = mccsVersion
        self.commands = commands
        self.vcp = vcp
    }

    public func entry(for code: VCPCode) -> Entry? {
        vcp.first { $0.code == code.rawValue }
    }

    public func lists(_ code: VCPCode) -> Bool {
        entry(for: code) != nil
    }

    /// The values listed for a code, one level deep: `60(0F 11 13)` gives
    /// 0x0F, 0x11 and 0x13.
    public func values(for code: VCPCode) -> [UInt8] {
        entry(for: code)?.values.map(\.code) ?? []
    }

    /// Parses a capabilities string. Never fails: anything it cannot make
    /// sense of is skipped, so a quirky display yields a partial result
    /// rather than none.
    public init(parsing string: String) {
        self.init()
        for (key, value) in Self.topLevelFields(of: string) {
            switch key.lowercased() {
            case "model": model = value.trimmingCharacters(in: .whitespaces)
            case "type": displayType = value.trimmingCharacters(in: .whitespaces)
            case "mccs_ver": mccsVersion = value.trimmingCharacters(in: .whitespaces)
            case "cmds": commands = Self.parseEntries(value).map(\.code)
            case "vcp": vcp = Self.parseEntries(value)
            default: break
            }
        }
    }

    /// Splits `key(value)key(value)…` at the top level, after removing the
    /// outer parentheses that most displays (but not all) wrap the string in.
    static func topLevelFields(of string: String) -> [(String, String)] {
        let body = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        guard body.first == "(" else { return fields(in: body) }
        guard let close = matchingParenthesis(in: body, openingAt: body.startIndex) else {
            // Truncated, for example by a failed read: drop the opening
            // parenthesis and keep what arrived.
            return fields(in: body.dropFirst())
        }
        // Inside the outer group, then whatever follows it: usually nothing,
        // sometimes padding or junk, which yields no fields.
        return fields(in: body[body.index(after: body.startIndex)..<close])
            + fields(in: body[body.index(after: close)...])
    }

    private static func fields(in body: Substring) -> [(String, String)] {
        var fields: [(String, String)] = []
        var cursor = body.startIndex
        while cursor < body.endIndex {
            guard let open = body[cursor...].firstIndex(of: "(") else { break }
            let key = body[cursor..<open].trimmingCharacters(in: .whitespaces)
            guard let close = matchingParenthesis(in: body, openingAt: open) else {
                // Unbalanced: take the rest as the value.
                fields.append((key, String(body[body.index(after: open)...])))
                break
            }
            fields.append((key, String(body[body.index(after: open)..<close])))
            cursor = body.index(after: close)
        }
        return fields
    }

    private static func matchingParenthesis(in text: Substring, openingAt open: Substring.Index) -> Substring.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            switch text[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Parses a list of hex bytes with optional nested lists, such as
    /// `02 04 60(0F 11 13) E1(04(00 01))`. Some displays run the bytes
    /// together without spaces (`020410`), which is handled too.
    static func parseEntries(_ text: String) -> [Entry] {
        var parser = EntryParser(Array(text.utf8))
        return parser.parseList()
    }

    private struct EntryParser {
        let bytes: [UInt8]
        var position = 0

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func parseList() -> [Entry] {
            var entries: [Entry] = []
            while position < bytes.count {
                let byte = bytes[position]
                if byte == UInt8(ascii: ")") {
                    position += 1
                    return entries
                }
                if byte == UInt8(ascii: "(") {
                    // A value list with no code before it: attach to the
                    // previous entry if there is one, otherwise skip it.
                    position += 1
                    let nested = parseList()
                    if !entries.isEmpty { entries[entries.count - 1].values += nested }
                    continue
                }
                guard Self.hexValue(byte) != nil else {
                    position += 1
                    continue
                }
                let run = hexRun()
                for code in run.dropLast() { entries.append(Entry(code: code)) }
                guard let last = run.last else { continue }
                var entry = Entry(code: last)
                skipSpaces()
                if position < bytes.count, bytes[position] == UInt8(ascii: "(") {
                    position += 1
                    entry.values = parseList()
                }
                entries.append(entry)
            }
            return entries
        }

        /// Reads a run of hex digits as bytes, two digits each. An odd
        /// trailing digit is dropped.
        private mutating func hexRun() -> [UInt8] {
            var digits: [UInt8] = []
            while position < bytes.count, let digit = Self.hexValue(bytes[position]) {
                digits.append(digit)
                position += 1
            }
            return stride(from: 0, to: digits.count - 1, by: 2).map { digits[$0] << 4 | digits[$0 + 1] }
        }

        private mutating func skipSpaces() {
            while position < bytes.count, bytes[position] == UInt8(ascii: " ") { position += 1 }
        }

        private static func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
            default: nil
            }
        }
    }
}
