import Foundation

/// Holds callers until it is opened. Lets a test freeze an operation halfway
/// and act while it is in flight, deterministically.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(open: Bool = false) {
        isOpen = open
    }

    var waiting: Int { waiters.count }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    /// Lets exactly the callers already waiting through, and stays closed.
    func release() {
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// Polls until `condition` holds. The budget is generous on purpose: it is
/// there to fail a hung test, not to assert speed.
func eventually(
    timeout: Duration = .seconds(10),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

/// Lets queued work run. Used before asserting that something did *not*
/// happen, where there is no condition to wait for.
func settle(isolation: isolated (any Actor)? = #isolation) async {
    for _ in 0..<50 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(20))
}
