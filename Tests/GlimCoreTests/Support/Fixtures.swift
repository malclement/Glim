import Foundation
@testable import GlimCore
import GlimTestSupport

enum Fixtures {
    static func text(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures") else {
            throw FixtureError.missing(name)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The HP E27m G4's capabilities string, exactly as it sends it.
    static func hpCapabilities() throws -> String {
        try text("hp-e27m-g4-capabilities").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One captured exchange: the section it belongs to and its frames.
    struct Capture {
        var section: String
        var written: [[UInt8]] = []
        var read: [[UInt8]] = []
    }

    /// The captured frames, by `## section`.
    static func hpFrames() throws -> [Capture] {
        var captures: [Capture] = []
        for line in try text("hp-e27m-g4-frames").split(separator: "\n") {
            if line.hasPrefix("## ") {
                captures.append(Capture(section: String(line.dropFirst(3))))
            } else if line.hasPrefix("  -> ") {
                // Drop the leading 51: it is the data address, not part of the frame.
                captures[captures.count - 1].written.append(Array(bytes(line.dropFirst(5)).dropFirst()))
            } else if line.hasPrefix("  <- ") {
                captures[captures.count - 1].read.append(bytes(line.dropFirst(5)))
            }
        }
        return captures
    }

    static func bytes(_ hex: some StringProtocol) -> [UInt8] {
        hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
    }

    static let hpIdentity = TestIdentity.hp
}

enum FixtureError: Error {
    case missing(String)
}
