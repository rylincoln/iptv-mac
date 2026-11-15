import Foundation

public enum PlayerState: Equatable, Sendable { case idle, opening, buffering, playing, ended, error }

public struct PlayerStats: Equatable, Sendable {
    public var positionMs: Int64
    public var displayedPictures: Int
    public var decodedAudioBlocks: Int
    public var lostPictures: Int
    public var inputBitrateKbps: Double

    public init(
        positionMs: Int64 = 0, displayedPictures: Int = 0, decodedAudioBlocks: Int = 0,
        lostPictures: Int = 0, inputBitrateKbps: Double = 0
    ) {
        self.positionMs = positionMs
        self.displayedPictures = displayedPictures
        self.decodedAudioBlocks = decodedAudioBlocks
        self.lostPictures = lostPictures
        self.inputBitrateKbps = inputBitrateKbps
    }

    public static let zero = PlayerStats()

    /// The highest input bitrate a reading may show: one gigabit per second.
    public static let maxKbps: Double = 1_000_000

    /// An input bitrate fit to show and to round to a whole number. The engine can hand back
    /// uninitialised memory as statistics, so a reading that is not a finite number is 0, and the rest
    /// is held to `0...maxKbps`.
    public static func sanitisedKbps(_ kbps: Double) -> Double {
        kbps.isFinite ? min(max(kbps, 0), maxKbps) : 0
    }
}

@MainActor public protocol Player: AnyObject {
    /// Replaces whatever is playing; implementations stop the old stream first. Before it returns,
    /// `sampleState` must no longer describe the old stream: a stale `.error` or `.ended` fails the new
    /// start on the supervisor's next tick. Likewise `stats` must already be the new stream's, counting
    /// from zero, since the supervisor reads them straight after as the baseline for progress.
    func play(url: URL, bufferMs: Int)
    func stop()
    /// 0...100
    var volume: Int { get set }
    /// Takes a reading of what the stream is doing. A method because taking one may change the
    /// next: an implementation may judge progress by the change since its previous reading
    /// (`VLCPlayer` does, see `PlaybackProgress`). So it is for `PlaybackSupervisor` alone, once a
    /// tick; a reading taken anywhere else could make a playing stream read as buffering there, which
    /// the supervisor counts as a rebuffer.
    func sampleState() -> PlayerState
    /// The counters as they stand. Reading them changes nothing, so anything may.
    var stats: PlayerStats { get }
}

public protocol BufferMemory: Sendable {
    func bufferMs(forStreamURL: String) -> Int?
    func setBufferMs(_ ms: Int, forStreamURL: String)
}

/// Errors are swallowed inside `Store`; a failed read is nil.
extension Store: BufferMemory {}

public struct SupervisorPolicy: Sendable {
    /// A new channel starts at the first step.
    public var bufferStepsMs = [1000, 2000, 4000, 8000]
    /// Opening/buffering with no progress: failed start.
    public var startTimeout: TimeInterval = 12
    /// Was progressing, then nothing: stall.
    public var stallAfter: TimeInterval = 4
    /// playing to buffering transitions...
    public var rebufferLimit = 3
    /// ...within this window: stutter.
    public var rebufferWindow: TimeInterval = 60
    /// Wait before attempt 1...5; then unavailable.
    public var retryDelays: [TimeInterval] = [1, 2, 5, 10, 20]
    /// Progressing this long resets the attempt count.
    public var stableAfter: TimeInterval = 60
    /// Progressing this long with no stall: one step down.
    public var stepDownAfter: TimeInterval = 30 * 60
    /// A tick this late means the Mac slept.
    public var wakeGap: TimeInterval = 30

    public init() {}

    public static let `default` = SupervisorPolicy()
}
