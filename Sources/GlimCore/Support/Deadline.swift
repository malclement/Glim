import os

/// Runs `operation`, giving up after `timeout` with ``DDCError/timedOut``.
///
/// A DDC transaction is a blocking call that cannot be interrupted, so a
/// structured timeout (a task group) would wait for it anyway. This returns as
/// soon as either side finishes, and whichever side loses is cancelled:
///
/// - On timeout, the operation's task is cancelled. A DDC operation still
///   queued behind a stuck one then sees the cancellation when it starts and
///   sends nothing, so a write the UI already reported as failed can never
///   reach the monitor later.
/// - Cancelling the caller cancels the operation, and returns at once with
///   `CancellationError`.
func withDeadline<T: Sendable>(
    _ timeout: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let race = DeadlineRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.begin(continuation, timeout: timeout, operation: operation)
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// The shared state of one ``withDeadline(_:_:)`` call. The first result
/// resumes the continuation; everything after it is dropped.
private final class DeadlineRace<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var finished = false
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func begin(_ continuation: CheckedContinuation<T, any Error>, timeout: Duration,
               operation: @escaping @Sendable () async throws -> T) {
        let alreadyFinished = state.withLock { state in
            if state.finished { return true }
            state.continuation = continuation
            return false
        }
        // Cancelled before it started.
        if alreadyFinished {
            continuation.resume(throwing: CancellationError())
            return
        }
        let work = Task {
            do {
                self.finish(.success(try await operation()))
            } catch {
                self.finish(.failure(error))
            }
        }
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self.finish(.failure(DDCError.timedOut))
        }
        let cancelNow = state.withLock { state in
            state.work = work
            state.timer = timer
            return state.finished
        }
        // Finished while the tasks were being created.
        if cancelNow {
            work.cancel()
            timer.cancel()
        }
    }

    func finish(_ result: Result<T, any Error>) {
        let (continuation, work, timer) = state.withLock { state -> (CheckedContinuation<T, any Error>?, Task<Void, Never>?, Task<Void, Never>?) in
            guard !state.finished else { return (nil, nil, nil) }
            state.finished = true
            defer { state.continuation = nil }
            return (state.continuation, state.work, state.timer)
        }
        // The loser stops: an expired operation is cancelled, a finished one
        // cancels its timer.
        work?.cancel()
        timer?.cancel()
        continuation?.resume(with: result)
    }
}
