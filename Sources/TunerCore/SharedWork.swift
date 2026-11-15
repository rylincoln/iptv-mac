import Synchronization

/// Runs one piece of work per key at a time, and gives its result, or its error, to every caller that
/// asks for that key while it runs.
///
/// Each caller can be cancelled on its own: it gets `CancellationError` at once, while the others go on
/// waiting. The work itself is cancelled only when every caller waiting on it has been, and a caller
/// asking after that starts the work again rather than joining the cancelled run. A caller already
/// cancelled when it asks starts nothing. A key is forgotten as soon as its work ends, so nothing is
/// kept beyond the work in flight.
public final class SharedWork<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct Run {
        /// Tells this run from a later one for the same key.
        var id: UInt64
        var task: Task<Void, Never>
        var waiters: [UInt64: CheckedContinuation<Value, any Error>]
    }

    private struct State {
        var runs: [Key: Run] = [:]
        var lastID: UInt64 = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// The value `work` produces for `key`, from a run already under way for the key or from a new one.
    /// Throws what the work throws, or `CancellationError` when the calling task is cancelled.
    public func value(for key: Key, work: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let id = state.withLock { state in
            state.lastID &+= 1
            return state.lastID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                join(key, id: id, continuation: continuation, work: work)
            }
        } onCancel: {
            leave(key, id: id)
        }
    }

    /// Waits on the key's run, starting it if there is none. A caller cancelled by now (whose
    /// `leave` found nothing to take away) is answered at once instead.
    private func join(
        _ key: Key, id: UInt64, continuation: CheckedContinuation<Value, any Error>,
        work: @escaping @Sendable () async throws -> Value
    ) {
        let joined = state.withLock { state in
            if Task.isCancelled { return false }
            if state.runs[key] != nil {
                state.runs[key]?.waiters[id] = continuation
                return true
            }
            // The run reports back under the lock, so it cannot finish before it is recorded here.
            let task = Task { [self] in
                let result: Result<Value, any Error>
                do { result = .success(try await work()) } catch { result = .failure(error) }
                finish(key, run: id, with: result)
            }
            state.runs[key] = Run(id: id, task: task, waiters: [id: continuation])
            return true
        }
        if !joined { continuation.resume(throwing: CancellationError()) }
    }

    /// A caller was cancelled: answers it, and cancels the run if no one else waits on it.
    private func leave(_ key: Key, id: UInt64) {
        let (continuation, abandoned) = state.withLock { state -> (CheckedContinuation<Value, any Error>?, Task<Void, Never>?) in
            guard let continuation = state.runs[key]?.waiters.removeValue(forKey: id) else { return (nil, nil) }
            guard let run = state.runs[key], run.waiters.isEmpty else { return (continuation, nil) }
            state.runs[key] = nil
            return (continuation, run.task)
        }
        abandoned?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    /// The run ended: answers everyone still waiting on it, unless it was abandoned meanwhile.
    private func finish(_ key: Key, run id: UInt64, with result: Result<Value, any Error>) {
        let waiters = state.withLock { state -> [CheckedContinuation<Value, any Error>] in
            guard let run = state.runs[key], run.id == id else { return [] }
            state.runs[key] = nil
            return Array(run.waiters.values)
        }
        for waiter in waiters { waiter.resume(with: result) }
    }

    // MARK: For tests

    /// Keys with a run under way.
    var inFlightCount: Int { state.withLock { $0.runs.count } }

    /// Callers waiting on the key's run.
    func waiterCount(for key: Key) -> Int { state.withLock { $0.runs[key]?.waiters.count ?? 0 } }
}
