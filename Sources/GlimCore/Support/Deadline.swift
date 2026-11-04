import os

/// Runs `operation`, giving up after `timeout` with ``DDCError/timedOut``.
///
/// A DDC transaction is a blocking call that cannot be interrupted, so a
/// structured timeout (a task group) would wait for it anyway. This returns as
/// soon as either side finishes; a transaction that overruns keeps its queue
/// until it completes, but no caller waits on it.
func withDeadline<T: Sendable>(
    _ timeout: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let claimed = OSAllocatedUnfairLock(initialState: false)
    /// True for exactly one caller: whoever finishes first resumes.
    let claim: @Sendable () -> Bool = {
        claimed.withLock { done in
            defer { done = true }
            return !done
        }
    }
    return try await withCheckedThrowingContinuation { continuation in
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            if claim() { continuation.resume(throwing: DDCError.timedOut) }
        }
        Task {
            do {
                let value = try await operation()
                timer.cancel()
                if claim() { continuation.resume(returning: value) }
            } catch {
                timer.cancel()
                if claim() { continuation.resume(throwing: error) }
            }
        }
    }
}
