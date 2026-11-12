import Foundation

/// One display's automatic brightness and evening warmth.
public struct AdaptiveSettings: Codable, Hashable, Sendable {
    public enum Source: String, Codable, CaseIterable, Sendable {
        /// The light in the room, from the Mac's sensor.
        case lightSensor
        /// The built-in display's brightness, which macOS already adapts.
        case followBuiltIn
        /// By time of day. Also what the other two fall back to when the lid
        /// is closed or their interface is missing.
        case schedule
    }

    /// Adjust brightness automatically.
    public var isEnabled = false
    public var source: Source = .lightSensor
    /// Bend the curve through every manual adjustment.
    public var learns = true
    public var lightCurve: BrightnessCurve = .lightDefault
    public var followCurve: BrightnessCurve = .followDefault
    public var schedule = DaySchedule()
    /// Warm the picture in the evening, by the schedule's times.
    public var warmsInEvening = false
    public var dayKelvin = 6500
    public var nightKelvin = 4500

    public init() {}

    /// The curve the source uses, nil for the schedule.
    public func curve(for source: Source) -> BrightnessCurve? {
        switch source {
        case .lightSensor: lightCurve
        case .followBuiltIn: followCurve
        case .schedule: nil
        }
    }

    public mutating func resetLearning() {
        lightCurve = .lightDefault
        followCurve = .followDefault
        schedule.dayBrightness = DaySchedule().dayBrightness
        schedule.nightBrightness = DaySchedule().nightBrightness
    }

    /// Color temperatures a stored value may have; anything else is taken
    /// for damage and replaced by the default.
    public static let kelvinRange = 1000...10000
}

// Decoding is tolerant: a field that is missing (written by an older
// release), unreadable or unknown (written by a newer one) takes its default,
// and the rest is kept. The encoded shape is what 0.4.0 wrote.
extension AdaptiveSettings {
    enum CodingKeys: String, CodingKey {
        case isEnabled, source, learns, lightCurve, followCurve, schedule, warmsInEvening, dayKelvin, nightKelvin
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = container.decode(.isEnabled, default: isEnabled)
        source = container.decode(.source, default: source)
        learns = container.decode(.learns, default: learns)
        lightCurve = container.decode(.lightCurve, default: lightCurve)
        followCurve = container.decode(.followCurve, default: followCurve)
        schedule = container.decode(.schedule, default: schedule)
        warmsInEvening = container.decode(.warmsInEvening, default: warmsInEvening)
        let day: Int = container.decode(.dayKelvin, default: dayKelvin)
        let night: Int = container.decode(.nightKelvin, default: nightKelvin)
        dayKelvin = Self.kelvinRange.contains(day) ? day : dayKelvin
        nightKelvin = Self.kelvinRange.contains(night) ? night : nightKelvin
    }
}

/// Day and night, by the clock, with a half-hour ramp between them.
///
/// With `dayStarts == nightStarts` the day is zero minutes long: it is always
/// night, brightness stays at `nightBrightness` and nothing divides or loops.
/// The values are kept as stored.
public struct DaySchedule: Codable, Hashable, Sendable {
    /// Minutes after midnight.
    public var dayStarts = 7 * 60
    public var nightStarts = 21 * 60
    public var dayBrightness = 0.9
    public var nightBrightness = 0.35

    public static let rampMinutes = 30.0

    public init() {}

    public enum Period: Sendable, Equatable { case day, night }

    public func period(at date: Date, calendar: Calendar = .current) -> Period {
        let minute = Self.minuteOfDay(date, calendar: calendar)
        return isDay(minute) ? .day : .night
    }

    /// How far into the day, 0 (night) to 1 (day), ramping over the half hour
    /// that follows each change.
    public func dayness(at date: Date, calendar: Calendar = .current) -> Double {
        let minute = Self.minuteOfDay(date, calendar: calendar)
        let sinceDay = Self.minutes(from: dayStarts, to: minute)
        let sinceNight = Self.minutes(from: nightStarts, to: minute)
        if isDay(minute) {
            return min(sinceDay / Self.rampMinutes, 1)
        }
        return max(1 - sinceNight / Self.rampMinutes, 0)
    }

    public func brightness(at date: Date, calendar: Calendar = .current) -> Double {
        let dayness = dayness(at: date, calendar: calendar)
        return nightBrightness + (dayBrightness - nightBrightness) * dayness
    }

    private func isDay(_ minute: Double) -> Bool {
        // Day is the stretch from dayStarts forward to nightStarts.
        Self.minutes(from: dayStarts, to: minute) < Self.minutes(from: dayStarts, to: Double(nightStarts))
    }

    private static func minuteOfDay(_ date: Date, calendar: Calendar) -> Double {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + Double(parts.second ?? 0) / 60
    }

    /// Minutes going forward from `start` to `minute`, wrapping at midnight.
    private static func minutes(from start: Int, to minute: Double) -> Double {
        let difference = minute - Double(start)
        return difference >= 0 ? difference : difference + 24 * 60
    }
}

extension DaySchedule {
    enum CodingKeys: String, CodingKey {
        case dayStarts, nightStarts, dayBrightness, nightBrightness
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func minute(_ key: CodingKeys, _ fallback: Int) -> Int {
            Self.clampedMinute(container.decode(key, default: fallback))
        }
        func level(_ key: CodingKeys, _ fallback: Double) -> Double {
            Self.clampedLevel(container.decode(key, default: fallback), fallback)
        }
        dayStarts = minute(.dayStarts, dayStarts)
        nightStarts = minute(.nightStarts, nightStarts)
        dayBrightness = level(.dayBrightness, dayBrightness)
        nightBrightness = level(.nightBrightness, nightBrightness)
    }

    /// Never writes a value that a decoder can't read back.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let defaults = DaySchedule()
        try container.encode(Self.clampedMinute(dayStarts), forKey: .dayStarts)
        try container.encode(Self.clampedMinute(nightStarts), forKey: .nightStarts)
        try container.encode(Self.clampedLevel(dayBrightness, defaults.dayBrightness), forKey: .dayBrightness)
        try container.encode(Self.clampedLevel(nightBrightness, defaults.nightBrightness), forKey: .nightBrightness)
    }

    private static func clampedMinute(_ minute: Int) -> Int { min(max(minute, 0), 24 * 60 - 1) }
    private static func clampedLevel(_ level: Double, _ fallback: Double) -> Double {
        level.isFinite ? min(max(level, 0), 1) : fallback
    }
}
