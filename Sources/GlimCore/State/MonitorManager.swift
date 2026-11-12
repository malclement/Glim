import Foundation
import Observation

/// Finds monitors, keeps the list current as they come and go, and owns each
/// ``Monitor``.
@MainActor
@Observable
public final class MonitorManager {
    public enum Availability: Equatable, Sendable {
        case available
        /// DDC/CI cannot work on this Mac at all.
        case unavailable(String)
    }

    /// Connected monitors, in a stable order (by display pipe).
    public private(set) var monitors: [Monitor] = []
    public private(set) var availability: Availability = .available
    /// True until the first scan has finished.
    public private(set) var isDiscovering = true
    /// Non-nil when DDC/CI is available and the last scan found no external
    /// display, yet the registry shows something that looks like one: a
    /// display is connected but Glim cannot use it, typically because a macOS
    /// release changed the registry. For the UI to explain an empty list.
    public private(set) var discoveryHint: String?
    /// Recent rare events, for the diagnostics report.
    public let events: EventLog

    @ObservationIgnored let platform: any MonitorPlatform
    /// One channel per transport. Every monitor object on a transport, the
    /// current one and any it replaced that may still be finishing, shares
    /// it, so all traffic on that I2C bus is serialised in one place.
    @ObservationIgnored private var channels: [UInt64: any DDCDevice] = [:]
    @ObservationIgnored private var stopObserving: (@MainActor () -> Void)?
    @ObservationIgnored private var pendingRescan: Task<Void, Never>?
    @ObservationIgnored private var isRescanning = false
    @ObservationIgnored private var rescanRequested = false
    @ObservationIgnored private var identityRetries = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lastDiscoveryCount: Int?
    /// Bumped by each audio association, so an older one that finishes late
    /// cannot undo a newer one.
    @ObservationIgnored private var audioGeneration = 0

    public init(platform: any MonitorPlatform = LivePlatform(), events: EventLog = EventLog()) {
        self.platform = platform
        self.events = events
    }

    // MARK: Lifecycle

    public func start() {
        guard !started else { return }
        started = true
        isDiscovering = true
        identityRetries = 0
        guard platform.isDDCAvailable else {
            availability = .unavailable(Self.unavailableMessage())
            isDiscovering = false
            Log.discovery.fault("IOAVService is unavailable; DDC/CI disabled")
            events.record("discovery", "DDC/CI unavailable: IOAVService interface missing")
            return
        }
        availability = .available
        stopObserving = platform.observeDisplayChanges { [weak self] in
            self?.identityRetries = 0
            self?.scheduleRescan()
        }
        scheduleRescan(after: .zero)
    }

    /// Why DDC/CI is unavailable. On Apple silicon the cause is a macOS
    /// release that no longer has the interface, not the hardware.
    nonisolated static func unavailableMessage(isAppleSilicon: Bool = MonitorManager.isAppleSilicon) -> String {
        isAppleSilicon
            ? "This version of macOS no longer provides the interface Glim uses to talk to displays. Check for a Glim update."
            : "Glim needs a Mac with Apple silicon. This Mac doesn't provide the DDC/CI interface Glim uses."
    }

    nonisolated static var isAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    /// Stops observing and releases every monitor.
    public func stop() {
        stopObserving?()
        stopObserving = nil
        pendingRescan?.cancel()
        pendingRescan = nil
        monitors.forEach { $0.invalidate() }
        monitors = []
        channels.removeAll()
        lastDiscoveryCount = nil
        started = false
    }

    // MARK: Discovery

    /// Rescans after `delay`, replacing a rescan already scheduled. Display
    /// changes arrive in bursts, so the default debounces them.
    public func scheduleRescan(after delay: Duration = .milliseconds(750)) {
        guard started, platform.isDDCAvailable else { return }
        pendingRescan?.cancel()
        pendingRescan = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            await self?.rescan()
        }
    }

    /// Updates ``monitors`` from the IORegistry. Monitors that are still
    /// connected keep their object (and their place in the UI); a monitor
    /// that comes back with a new transport is reconnected rather than
    /// replaced.
    public func rescan() async {
        guard started else { return }
        if isRescanning {
            rescanRequested = true
            return
        }
        isRescanning = true
        defer { isRescanning = false }
        repeat {
            rescanRequested = false
            let displays = await platform.discoverDisplays()
            guard started else { return }
            apply(displays)
            noteDiscovery(displays)
            await associateAudio()
            // A framebuffer's EDID can be published a moment after its
            // transport. Look again shortly rather than show a nameless display.
            if displays.contains(where: { $0.identity == nil }), identityRetries < 3 {
                identityRetries += 1
                scheduleRescan(after: .seconds(2))
            }
        } while rescanRequested
        isDiscovering = false
    }

    /// Logs and records a change in how many displays the scan found, and
    /// updates ``discoveryHint``.
    private func noteDiscovery(_ displays: [DiscoveredDisplay]) {
        if lastDiscoveryCount != displays.count {
            Log.discovery.notice("scan found \(displays.count) external display(s)")
            events.record("discovery", "scan found \(displays.count) external display(s)")
            lastDiscoveryCount = displays.count
        }
        var hint: String?
        if displays.isEmpty {
            let summary = platform.transportSummary
            if summary.suggestsUnusableDisplay {
                hint = "A display is connected, but Glim can't reach it on this version of macOS."
                if discoveryHint == nil { events.record("discovery", "registry shows a display Glim cannot use") }
            }
        }
        // Observation re-renders on every assignment, even of an equal value.
        if discoveryHint != hint { discoveryHint = hint }
    }

    private func apply(_ displays: [DiscoveredDisplay]) {
        let keys = Self.monitorKeys(for: displays)
        var next: [Monitor] = []
        for (display, key) in zip(displays, keys) {
            if let existing = monitors.first(where: { $0.id == key }) {
                if existing.display.serviceID != display.serviceID {
                    events.record("state", "\(existing.name) reconnected")
                    existing.reconnect(to: display, device: channel(for: display))
                }
                next.append(existing)
            } else {
                let label = display.identity?.productName ?? "unidentified display"
                Log.discovery.notice("monitor connected: \(label, privacy: .public)")
                events.record("discovery", "monitor connected: \(label)")
                let monitor = Monitor(id: key, display: display, device: channel(for: display), timing: platform.controlTiming,
                                      events: events)
                monitor.start()
                next.append(monitor)
            }
        }
        for monitor in monitors where !next.contains(where: { $0 === monitor }) {
            Log.discovery.notice("monitor gone: \(monitor.name, privacy: .public)")
            events.record("discovery", "monitor gone: \(monitor.name)")
            monitor.invalidate()
        }
        monitors = next
        let live = Set(displays.map(\.serviceID))
        channels = channels.filter { live.contains($0.key) }
    }

    private func channel(for display: DiscoveredDisplay) -> any DDCDevice {
        if let existing = channels[display.serviceID] { return existing }
        let channel = platform.makeDevice(for: display)
        channels[display.serviceID] = channel
        return channel
    }

    /// A key per display that survives reconnects. Two identical monitors
    /// without a usable serial share an EDID key, so those also get their
    /// display pipe.
    static func monitorKeys(for displays: [DiscoveredDisplay]) -> [String] {
        func counts(_ keys: [String]) -> [String: Int] {
            keys.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }
        let base = displays.map { $0.identity?.stableKey ?? "unidentified-\($0.serviceID)" }
        let baseCounts = counts(base)
        let piped = zip(base, displays).map { key, display in
            (baseCounts[key] ?? 0) > 1 ? "\(key)@\(display.framebuffer ?? String(display.serviceID))" : key
        }
        // Still equal (same EDID on the same pipe, for instance an old and a
        // new transport seen together): the transport tells them apart.
        let pipedCounts = counts(piped)
        return zip(piped, displays).map { key, display in
            (pipedCounts[key] ?? 0) > 1 ? "\(key)#\(display.serviceID)" : key
        }
    }

    // MARK: Audio

    /// Ties each monitor whose speakers are a USB Audio device to that device.
    /// When it cannot tell which device belongs to which monitor, it ties none
    /// rather than guess, because a wrong guess changes some other speaker's
    /// volume. That covers two monitors of the same model, and any connected
    /// display whose EDID is not known yet, which could be one more of them.
    private func associateAudio() async {
        audioGeneration &+= 1
        let generation = audioGeneration
        let wanting = monitors.filter { if case .usbAudio = $0.profile.volume { true } else { false } }
        guard !wanting.isEmpty else { return }
        let outputs = await platform.audioOutputs()
        // A newer association started while this one waited: it wins.
        guard generation == audioGeneration, started else { return }
        let unidentified = monitors.contains { $0.identity == nil }
        for monitor in wanting where monitors.contains(where: { $0 === monitor }) {
            guard case .usbAudio(let prefix) = monitor.profile.volume else { continue }
            let candidates = outputs.filter { $0.isUSB && $0.name.hasPrefix(prefix) }
            let sameModel = wanting.filter { $0.profile.volume == monitor.profile.volume }
            let unambiguous = candidates.count == 1 && sameModel.count == 1 && !unidentified
            if !unambiguous, !candidates.isEmpty {
                let reason = "\(candidates.count) audio device(s) for \(sameModel.count) \(prefix) monitor(s)\(unidentified ? " and an unidentified display" : ""); not guessing"
                Log.audio.notice("\(reason, privacy: .public)")
                events.record("audio", reason)
            }
            monitor.attachAudio(unambiguous ? candidates.first : nil, make: platform.makeAudioOutput)
        }
    }

    // MARK: Presentation

    /// The monitor's name, numbered when another connected monitor has the
    /// same one, in display-pipe order: "HP E27m G4 (1)", "HP E27m G4 (2)".
    public func title(for monitor: Monitor) -> String {
        let namesakes = monitors.filter { $0.name == monitor.name }
        guard namesakes.count > 1, let index = namesakes.firstIndex(where: { $0 === monitor }) else { return monitor.name }
        return "\(monitor.name) (\(index + 1))"
    }

    // MARK: Refresh

    /// Re-reads every monitor, unless it was read in the last two seconds.
    /// Called when the menu opens: Glim does not poll in the background.
    public func refresh() async {
        guard started, platform.isDDCAvailable else { return }
        await associateAudio()
        await withTaskGroup(of: Void.self) { group in
            for monitor in monitors {
                group.addTask { await monitor.refreshIfStale() }
            }
        }
    }
}
