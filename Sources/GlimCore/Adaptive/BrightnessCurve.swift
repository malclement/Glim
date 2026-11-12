import Foundation

/// Brightness, 0 to 1, as a function of a light reading. Piecewise linear
/// between its points, flat beyond them, and never decreasing: more light
/// never means a dimmer screen.
///
/// For the light sensor the reading is `log10(lux + 1)`, so equal steps are
/// equal ratios of light, as the eye sees them. For "follow the MacBook
/// screen" it is the built-in display's brightness, 0 to 1.
public struct BrightnessCurve: Codable, Hashable, Sendable {
    public struct Point: Codable, Hashable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// Sorted by `x`, at least two, and `y` never decreases.
    public private(set) var points: [Point]

    public init(points: [Point]) {
        self.points = Self.normalized(points)
    }

    private enum CodingKeys: String, CodingKey { case points }

    /// Goes through the same normalisation as ``init(points:)``: sorted,
    /// monotonic, finite, `y` within 0 to 1. Points that can't be read, or
    /// aren't numbers, are dropped. If none is left it throws, so the owner
    /// can substitute the default curve that suits it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = container.decodeLossyArray(.points, of: Point.self) ?? []
        guard stored.contains(where: { $0.x.isFinite && $0.y.isFinite }) else {
            throw DecodingError.dataCorruptedError(forKey: .points, in: container, debugDescription: "no usable point")
        }
        self.init(points: stored)
    }

    /// About 20% in the dark, rising to 100% at 1000 lux (an overcast
    /// daylit room), over log(lux).
    public static let lightDefault = BrightnessCurve(points: [Point(x: 0, y: 0.20), Point(x: lightReading(lux: 1000), y: 1)])
    /// The MacBook screen's brightness, with a floor so the external display
    /// never goes fully dark.
    public static let followDefault = BrightnessCurve(points: [Point(x: 0, y: 0.10), Point(x: 1, y: 1)])

    /// The curve's reading for a light level.
    public static func lightReading(lux: Double) -> Double {
        log10(max(lux, 0) + 1)
    }

    /// Points closer than this in `x` are one point.
    static let mergeDistance = 0.12
    static let maximumPoints = 12

    public func brightness(at x: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 1 }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        for (left, right) in zip(points, points.dropFirst()) where x <= right.x {
            let span = right.x - left.x
            return span > 0 ? left.y + (right.y - left.y) * (x - left.x) / span : right.y
        }
        return last.y
    }

    /// Bends the curve through (x, y), the user's choice at that light. The
    /// rest of the curve gives way just enough to stay monotonic: a point
    /// left of it that is brighter comes down to it, and one right of it
    /// that is dimmer comes up to it.
    public mutating func learn(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return }
        let y = min(max(y, 0), 1)
        var points = self.points.filter { abs($0.x - x) >= Self.mergeDistance }
        for index in points.indices {
            if points[index].x < x { points[index].y = min(points[index].y, y) }
            if points[index].x > x { points[index].y = max(points[index].y, y) }
        }
        points.append(Point(x: x, y: y))
        // Too many points: drop the inner point whose neighbours are
        // closest, never the one just learned.
        while points.count > Self.maximumPoints {
            let sorted = points.sorted { $0.x < $1.x }
            let inner = sorted.indices.dropFirst().dropLast().filter { sorted[$0].x != x }
            func span(_ index: Int) -> Double { sorted[index + 1].x - sorted[index - 1].x }
            guard let drop = inner.min(by: { span($0) < span($1) }) else { break }
            points = sorted
            points.remove(at: drop)
        }
        self.points = Self.normalized(points)
    }

    private static func normalized(_ points: [Point]) -> [Point] {
        // Never hold a value that can't be saved or compared: non-finite
        // points are dropped and brightness stays within 0 to 1.
        let usable = points.filter { $0.x.isFinite && $0.y.isFinite }.map { Point(x: $0.x, y: min(max($0.y, 0), 1)) }
        var sorted = usable.sorted { $0.x < $1.x }
        if sorted.isEmpty { sorted = [Point(x: 0, y: 1)] }
        if sorted.count == 1 { sorted.append(Point(x: sorted[0].x + 1, y: sorted[0].y)) }
        // Never decreasing: a later point is at least as bright.
        for index in sorted.indices.dropFirst() where sorted[index].y < sorted[index - 1].y {
            sorted[index].y = sorted[index - 1].y
        }
        return sorted
    }
}
