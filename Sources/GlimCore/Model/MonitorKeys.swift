import Foundation

/// Whether `id` is a key of a display whose EDID is not known yet
/// (`unidentified-<serviceID>`). That key changes on every reconnect, so
/// nothing may be stored under it: such a display has no stable identity.
public func isTransientMonitorID(_ id: String) -> Bool {
    id.hasPrefix("unidentified-")
}

/// `id` without the suffix ``MonitorManager/monitorKeys(for:)`` adds when
/// identical monitors cannot be told apart by EDID: `@<pipe or serviceID>`,
/// then possibly `#<serviceID>`. `ABC-1234@dispext1#99` gives `ABC-1234`.
///
/// The suffix is only stripped when it has exactly that shape, at the very
/// end, so an id without one (including a serial that happens to contain
/// `@` or `#` elsewhere) comes back unchanged. A serial ending in
/// `@something` is indistinguishable from a pipe suffix; that is accepted.
public func baseMonitorID(_ id: String) -> String {
    guard let at = id.lastIndex(of: "@"), at != id.startIndex else { return id }
    let suffix = id[id.index(after: at)...]
    var pipe = suffix
    if let hash = suffix.lastIndex(of: "#") {
        let digits = suffix[suffix.index(after: hash)...]
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return id }
        pipe = suffix[..<hash]
    }
    guard !pipe.isEmpty, !pipe.contains("#") else { return id }
    return String(id[..<at])
}

/// The entry stored for `id`: the exact id first, then the base id, then
/// (when `id` is itself a base) an entry of a sibling that has a suffix, the
/// first in alphabetical order.
///
/// The cost: two identical monitors without a serial share the fallback
/// entry until each is changed, because a write always goes to the exact id
/// and from then on shadows the shared one. That is better than losing the
/// settings of a lone monitor the moment its twin is plugged in.
public func monitorValue<Value>(in entries: [String: Value], for id: String) -> Value? {
    if let exact = entries[id] { return exact }
    return fallbackMonitorValue(in: entries, for: id)
}

/// ``monitorValue(in:for:)`` without the exact id: what `id` inherits.
public func fallbackMonitorValue<Value>(in entries: [String: Value], for id: String) -> Value? {
    let base = baseMonitorID(id)
    if base != id, let value = entries[base] { return value }
    guard base == id else { return nil }
    let sibling = entries.keys.filter { $0 != id && baseMonitorID($0) == id }.min()
    return sibling.flatMap { entries[$0] }
}
