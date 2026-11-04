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

    @ObservationIgnored private let platform: any MonitorPlatform
    @ObservationIgnored private var stopObserving: (@MainActor () -> Void)?
    @ObservationIgnored private var pendingRescan: Task<Void, Never>?
    @ObservationIgnored private var isRescanning = false
    @ObservationIgnored private var rescanRequested = false
    @ObservationIgnored private var identityRetries = 0
    @ObservationIgnored private var started = false

    public init(platform: any MonitorPlatform = LivePlatform()) {
        self.platform = platform
    }

    // MARK: Lifecycle

    public func start() {
        guard !started else { return }
        started = true
        guard platform.isDDCAvailable else {
            availability = .unavailable("Glim needs a Mac with Apple silicon. This Mac doesn't provide the DDC/CI interface Glim uses.")
            isDiscovering = false
            Log.discovery.fault("IOAVService is unavailable; DDC/CI disabled")
            return
        }
        availability = .available
        stopObserving = platform.observeDisplayChanges { [weak self] in
            self?.identityRetries = 0
            self?.scheduleRescan()
        }
        scheduleRescan(after: .zero)
    }

    /// Stops observing and releases every monitor.
    public func stop() {
        stopObserving?()
        stopObserving = nil
        pendingRescan?.cancel()
        pendingRescan = nil
        monitors.forEach { $0.invalidate() }
        monitors = []
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

    private func apply(_ displays: [DiscoveredDisplay]) {
        let keys = Self.monitorKeys(for: displays)
        var next: [Monitor] = []
        for (display, key) in zip(displays, keys) {
            if let existing = monitors.first(where: { $0.id == key }) {
                if existing.display.serviceID != display.serviceID {
                    existing.reconnect(to: display, device: platform.makeDevice(for: display))
                }
                next.append(existing)
            } else {
                Log.discovery.info("monitor connected: \(display.identity?.productName ?? "unidentified", privacy: .public)")
                let monitor = Monitor(id: key, display: display, device: platform.makeDevice(for: display), timing: platform.controlTiming)
                monitor.start()
                next.append(monitor)
            }
        }
        for monitor in monitors where !next.contains(where: { $0 === monitor }) {
            Log.discovery.info("monitor disconnected: \(monitor.name, privacy: .public)")
            monitor.invalidate()
        }
        monitors = next
    }

    /// A key per display that survives reconnects. Two identical monitors
    /// without a usable serial share an EDID key, so those also get their
    /// display pipe.
    static func monitorKeys(for displays: [DiscoveredDisplay]) -> [String] {
        let base = displays.map { $0.identity?.stableKey ?? "unidentified-\($0.serviceID)" }
        let counts = base.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return zip(base, displays).map { key, display in
            (counts[key] ?? 0) > 1 ? "\(key)@\(display.framebuffer ?? String(display.serviceID))" : key
        }
    }

    // MARK: Audio

    /// Ties each monitor whose speakers are a USB Audio device to that device.
    /// When it cannot tell which device belongs to which monitor (two of the
    /// same model connected), it ties none rather than guess: a wrong guess
    /// would change some other speaker's volume.
    private func associateAudio() async {
        let wanting = monitors.filter { if case .usbAudio = $0.profile.volume { true } else { false } }
        guard !wanting.isEmpty else { return }
        let outputs = await platform.audioOutputs()
        for monitor in wanting {
            guard case .usbAudio(let prefix) = monitor.profile.volume else { continue }
            let candidates = outputs.filter { $0.isUSB && $0.name.hasPrefix(prefix) }
            let sameModel = wanting.filter { $0.profile.volume == monitor.profile.volume }
            let device = candidates.count == 1 && sameModel.count == 1 ? candidates.first : nil
            if device == nil, !candidates.isEmpty {
                Log.audio.notice("\(candidates.count) audio devices for \(sameModel.count) \(prefix, privacy: .public) monitor(s); not guessing")
            }
            monitor.attachAudio(device, make: platform.makeAudioOutput)
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
