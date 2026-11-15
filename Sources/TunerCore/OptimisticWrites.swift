/// Writes shown on screen before they are made, and the reads that could undo them.
///
/// A store write can wait behind another (an import's one long transaction), so its change is shown at
/// once and written later. A read made meanwhile can find the store without it, and showing that read
/// would put the change back on screen. So a read that can wait (`mayRead`) waits until every write
/// has ended. A read that cannot wait is shown, then checked (`check`) against the ticket taken as it
/// started: if it overlapped a write, it is read again once the writes have all ended, or at once if
/// they already have. Nothing is kept once the last write ends, and nothing at all while none runs.
public struct OptimisticWrites<Read: Hashable & Sendable>: Sendable {
    public enum Freshness: Sendable, Equatable {
        /// No write ran while it was read.
        case current
        /// A write is still unfinished; the read is given back by `end` once the last one ends.
        case heldUntilWritten
        /// A write ran while it was read and every write has ended since: read it again now.
        case readAgainNow
    }

    /// Taken as a read starts; `check` compares against it.
    public struct Ticket: Sendable, Equatable {
        fileprivate let ended: UInt64
    }

    /// What to do with a read that has come back (`use`).
    public struct Use: Sendable, Equatable {
        /// Show what was read.
        public var show: Bool
        /// Make the read again now: a write ran while it was read, and every write has ended since.
        public var readAgain: Bool

        public init(show: Bool, readAgain: Bool) {
            self.show = show
            self.readAgain = readAgain
        }
    }

    /// Writes begun and not yet ended.
    public private(set) var unfinished = 0
    /// Writes ended, ever. It moves whenever a write ends, so a ticket shows whether one did.
    private var ended: UInt64 = 0
    private var held: Set<Read> = []

    public init() {}

    /// A change has been shown and its write started.
    public mutating func begin() {
        unfinished += 1
    }

    /// A write ended, made or not. When it was the last, the reads held for the writes, which are then
    /// forgotten (often none); nil while others remain, and for an `end` with no write unfinished.
    public mutating func end() -> Set<Read>? {
        guard unfinished > 0 else { return nil }
        unfinished -= 1
        ended &+= 1
        guard unfinished == 0 else { return nil }
        defer { held = [] }
        return held
    }

    public var ticket: Ticket { Ticket(ended: ended) }

    /// For a read that need not be made now: true when no write is unfinished. Otherwise false, and the
    /// read is held until the last write ends (`end`).
    public mutating func mayRead(_ read: Read) -> Bool {
        guard unfinished > 0 else { return true }
        held.insert(read)
        return false
    }

    /// Holds a read until the last write ends, whatever is unfinished now: for a write that failed,
    /// whose change shown must be read back from the store once nothing more can change it.
    public mutating func hold(_ read: Read) {
        held.insert(read)
    }

    /// For a read that has come back and been shown, begun when `ticket` was taken.
    public mutating func check(_ read: Read, since ticket: Ticket) -> Freshness {
        if unfinished > 0 {
            held.insert(read)
            return .heldUntilWritten
        }
        return ticket.ended == ended ? .current : .readAgainNow
    }

    /// For a read that has come back, begun when `ticket` was taken: whether to show it, and whether to
    /// make it again now. A read that overlapped a write may have missed it. One that would replace what
    /// is shown (`replacingShown`: the same list or results read again) is then not shown, as it would
    /// put the change back on screen; one of something new (a section just chosen, text just typed) has
    /// nothing else to show it, so it is shown. Either way it is made again once the writes have ended,
    /// as with `check`.
    public mutating func use(_ read: Read, since ticket: Ticket, replacingShown: Bool) -> Use {
        switch check(read, since: ticket) {
        case .current: Use(show: true, readAgain: false)
        case .heldUntilWritten: Use(show: !replacingShown, readAgain: false)
        case .readAgainNow: Use(show: !replacingShown, readAgain: true)
        }
    }
}
