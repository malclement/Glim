import Foundation

/// Decodes to nil instead of throwing, so one bad element of an array or
/// dictionary doesn't discard the rest. Used for everything Glim persists:
/// data written by an older or a newer release must load as far as it can.
public struct Lossy<Value: Decodable>: Decodable {
    public let value: Value?

    public init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// The value for `key`, or `fallback` when it is absent, null, of the
    /// wrong type or not a case this release knows.
    public func decode<T: Decodable>(_ key: Key, default fallback: @autoclosure () -> T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback()
    }

    /// The optional value for `key`, nil when anything is wrong with it.
    public func decodeOptional<T: Decodable>(_ key: Key) -> T? {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil)
    }

    /// The elements of the array for `key` that decode; nil when the key is
    /// absent or not an array.
    public func decodeLossyArray<T: Decodable>(_ key: Key, of type: T.Type = T.self) -> [T]? {
        guard let elements = try? decodeIfPresent([Lossy<T>].self, forKey: key) else { return nil }
        return elements.compactMap(\.value)
    }

    /// The entries of the dictionary for `key` that decode; nil when the key
    /// is absent or not an object.
    public func decodeLossyDictionary<T: Decodable>(_ key: Key, of type: T.Type = T.self) -> [String: T]? {
        guard let entries = try? decodeIfPresent([String: Lossy<T>].self, forKey: key) else { return nil }
        return entries.compactMapValues(\.value)
    }
}

/// What ``decodeLossily(_:from:)`` found.
public struct LossyDecoding<Value> {
    public var value: Value
    /// How many elements could not be read and were left out.
    public var skipped: Int
}

/// Decodes the array in `data` element by element. Throws only when `data`
/// is not an array at all.
public func decodeLossyArray<T: Decodable>(_ type: T.Type, from data: Data) throws -> LossyDecoding<[T]> {
    let all = try JSONDecoder().decode([Lossy<T>].self, from: data)
    let kept = all.compactMap(\.value)
    return LossyDecoding(value: kept, skipped: all.count - kept.count)
}

/// Decodes the object in `data` value by value. Throws only when `data` is
/// not an object at all.
public func decodeLossyDictionary<T: Decodable>(_ type: T.Type, from data: Data) throws -> LossyDecoding<[String: T]> {
    let all = try JSONDecoder().decode([String: Lossy<T>].self, from: data)
    let kept = all.compactMapValues(\.value)
    return LossyDecoding(value: kept, skipped: all.count - kept.count)
}
