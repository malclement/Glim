import Foundation

/// What Glim 0.3.0 and 0.4.0 wrote to `UserDefaults`, captured by encoding
/// the types of those releases (keys sorted). New code must read all of it,
/// and what it writes must stay readable by those releases.
public enum PersistenceFixtures {
    public static let sceneID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    /// `scenes`, 0.3.0 and 0.4.0 (unchanged between them).
    public static let scenes = """
    [{"id":"11111111-2222-3333-4444-555555555555","includes":["brightness","color"],"monitors":{"HPN-3753-A1":{"brightness":{"maximum":100,"value":30},"color":{"preset":{"name":"Warm","value":5}},"contrast":{"maximum":100,"value":50},"monitorName":"HP E27m"},"HPN-3753-B2":{"color":{"temperature":{"kelvin":5000,"steps":12}},"monitorName":"Other"}},"name":"Evening","symbol":"moon"}]
    """

    /// `displays`, 0.3.0 and 0.4.0.
    public static let displays = """
    {"HPN-3753-A1":{"name":"Desk","rows":{"volume":false},"showsInMenu":false}}
    """

    /// `adaptive`, 0.4.0.
    public static let adaptive = """
    {"HPN-3753-A1":{"dayKelvin":6000,"followCurve":{"points":[{"x":0,"y":0.1},{"x":1,"y":1}]},"isEnabled":true,"learns":false,"lightCurve":{"points":[{"x":0,"y":0.2},{"x":1.5,"y":0.6},{"x":3,"y":1}]},"nightKelvin":4000,"schedule":{"dayBrightness":0.9,"dayStarts":400,"nightBrightness":0.35,"nightStarts":1260},"source":"followBuiltIn","warmsInEvening":true}}
    """
}
