/// Runs the searches a search field asks for as its text changes, so that only the latest text's
/// results are ever delivered.
///
/// - A search waits out a pause in the typing first; text that changes meanwhile starts over.
/// - A read already running cannot be stopped, so the next one waits for it to finish: two never
///   run at once. Its results are dropped unless they are still for the latest text.
/// - A refresh reads again for text whose results already show (on the minute, say). It does
///   nothing while a search waits or runs, since that search reads afresh anyway, and a search
///   for new text cancels it.
///
/// `read` returns nil for a read that failed; nothing is delivered then, so what shows is kept.
@MainActor public final class LatestSearch<Found: Sendable> {
    public typealias Read = @MainActor () async -> Found?

    private let sleep: @Sendable (Duration) async throws -> Void
    /// The search or refresh waiting for its turn, or for its read.
    private var waiting: Task<Void, Never>?
    /// The read running, if any. It runs to its end whatever becomes of the search that began it.
    private var running: Task<Found?, Never>?
    /// The text last searched for; nil once `cancel`led.
    private var text: String?
    private var searchesStarted: UInt64 = 0
    /// The search that waits or runs; it marks itself done.
    private var searchUnderWay: UInt64?

    /// `sleep` waits out the pause, and throws if cancelled meanwhile.
    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// A search waits or runs. A refresh does not count.
    public var isSearching: Bool { searchUnderWay != nil }

    /// Searches for `text` after `pause` with no further call. `found` is called with what `read`
    /// returned unless it failed, or `search` or `cancel` was called meanwhile. By then the search is
    /// over, so `found` may ask for a refresh.
    public func search(_ text: String, after pause: Duration, read: @escaping Read, found: @escaping @MainActor (Found) -> Void) {
        cancel()
        self.text = text
        searchesStarted &+= 1
        let search = searchesStarted
        searchUnderWay = search
        waiting = Task {
            // Marked done however it ends; a search cancelled for a newer one leaves the newer one's mark.
            defer { if searchUnderWay == search { searchUnderWay = nil } }
            do { try await sleep(pause) } catch { return }
            guard let result = await result(of: read, for: text) else { return }
            searchUnderWay = nil
            found(result)
        }
    }

    /// Reads again for `text`, at once, unless a search waits or runs. `found` is called as for
    /// `search`; a later `refresh` replaces this one.
    public func refresh(_ text: String, read: @escaping Read, found: @escaping @MainActor (Found) -> Void) {
        guard searchUnderWay == nil, text == self.text else { return }
        waiting?.cancel()
        waiting = Task {
            if let result = await result(of: read, for: text) { found(result) }
        }
    }

    /// Drops whatever waits or runs: nothing more is delivered until the next `search`.
    public func cancel() {
        waiting?.cancel()
        waiting = nil
        searchUnderWay = nil
        text = nil
    }

    /// Waits for the read running, runs this one, and returns what it found if that is still wanted.
    private func result(of read: @escaping Read, for text: String) async -> Found? {
        _ = await running?.value
        guard !Task.isCancelled else { return nil }
        let run = Task { await read() }
        running = run
        let found = await run.value
        if running == run { running = nil }  // finished: nothing to wait for, nothing kept
        guard !Task.isCancelled, text == self.text else { return nil }
        return found
    }
}
