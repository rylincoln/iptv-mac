import AppKit
import TunerCore
import VLCKit

/// The app's one VLCKit player, so there is never more than one stream open.
///
/// VLCKit's own state cannot be trusted as "is it playing": on a healthy live stream it sticks at
/// buffering for the whole session. So `state` reports `.playing` while the media is actually
/// advancing, `.buffering` only when VLCKit says buffering and nothing has advanced since the
/// previous reading, and `.ended` / `.error` as VLCKit reports them.
///
/// VLCKit delivers its events asynchronously on the main queue, so events from the previous stream
/// can still arrive after `play` returns. Each `play` queues a fence behind them and ignores every
/// event until the fence has run.
@MainActor final class VLCPlayer: NSObject, Player {
    let videoView: NSView

    /// Readings closer together than this reuse the previous verdict, so two reads in a row never
    /// look like a stall.
    private static let minSampleInterval: TimeInterval = 0.5

    /// The last VLCKit state event accepted for the current play call.
    private enum EngineEvent { case none, opening, buffering, running, ended, error }

    private let vlcView: VLCVideoView
    private var engine: VLCMediaPlayer?       // created on the first play, so launch does not start libVLC
    private var media: VLCMedia?              // the current play call's media; nil when stopped
    private var generation = 0
    private var acceptingEvents = false
    private var lastEvent = EngineEvent.none
    private var positionMs: Int64 = 0
    private var sample = PlayerStats.zero      // counters at the previous reading
    private var sampledAt: TimeInterval = 0
    private var advancing = false
    private var hasAdvanced = false
    private var volumeLevel = 100

    override init() {
        let view = VLCVideoView(frame: .zero)
        view.backColor = .black
        vlcView = view
        videoView = view
        super.init()
    }

    // MARK: Player

    func play(url: URL, bufferMs: Int) {
        stop()
        let engine = self.engine ?? makeEngine()
        let fence = generation
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == fence else { return }
                self.acceptingEvents = true
            }
        }
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=\(max(0, bufferMs))")
        self.media = media
        sampledAt = ProcessInfo.processInfo.systemUptime
        engine.media = media
        engine.play()
    }

    func stop() {
        generation &+= 1
        acceptingEvents = false
        if media != nil { engine?.stop() }
        media = nil
        lastEvent = .none
        positionMs = 0
        sample = .zero
        advancing = false
        hasAdvanced = false
    }

    var volume: Int {
        get { volumeLevel }
        set {
            volumeLevel = min(max(newValue, 0), 100)
            engine?.audio?.volume = Int32(volumeLevel)
        }
    }

    var state: PlayerState {
        guard media != nil else { return .idle }
        switch lastEvent {
        case .none: return .opening
        case .ended: return .ended
        case .error: return .error
        case .opening, .buffering, .running: break
        }
        sampleProgress()
        if advancing { return .playing }
        if lastEvent == .buffering { return .buffering }
        return hasAdvanced ? .playing : .opening
    }

    var stats: PlayerStats {
        // Until the first event of this play call the media has no input, and VLCKit then returns
        // uninitialised memory as statistics. Even after it, the bitrate (a float, in kilobytes per
        // millisecond) is sanitised, so the overlay's whole-number reading can never trap.
        guard let media, lastEvent != .none else { return .zero }
        let counters = media.statistics
        return PlayerStats(
            positionMs: positionMs,
            displayedPictures: Int(counters.displayedPictures),
            decodedAudioBlocks: Int(counters.decodedAudio),
            lostPictures: Int(counters.lostPictures),
            inputBitrateKbps: PlayerStats.sanitisedKbps(Double(counters.inputBitrate) * 8000))
    }

    // MARK: Private

    private func makeEngine() -> VLCMediaPlayer {
        let engine = VLCMediaPlayer(videoView: vlcView)
        engine.delegate = self
        engine.audio?.volume = Int32(volumeLevel)
        self.engine = engine
        return engine
    }

    /// Compares the counters with the previous reading.
    private func sampleProgress() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - sampledAt >= Self.minSampleInterval else { return }
        let current = stats
        let moved = current.positionMs > sample.positionMs
            || current.displayedPictures > sample.displayedPictures
            || current.decodedAudioBlocks > sample.decodedAudioBlocks
        advancing = moved && engine?.isPlaying == true
        if advancing { hasAdvanced = true }
        sample = current
        sampledAt = now
    }

    fileprivate func engineStateChanged() {
        guard acceptingEvents, let engine else { return }
        if lastEvent == .ended || lastEvent == .error { return }  // final for this play call
        switch engine.state {
        case .opening: lastEvent = .opening
        case .buffering: lastEvent = .buffering
        case .playing, .esAdded, .paused: lastEvent = .running
        case .ended: lastEvent = .ended
        case .error: lastEvent = .error
        case .stopped: break  // only our own stop produces this, and it comes before the fence
        @unknown default: break
        }
    }

    fileprivate func engineTimeChanged() {
        guard acceptingEvents, let engine else { return }
        positionMs = Int64(engine.time.intValue)
    }
}

// VLCKit calls these on the main queue, from the block that has just updated `state` and `time`.
extension VLCPlayer: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        MainActor.assumeIsolated { engineStateChanged() }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        MainActor.assumeIsolated { engineTimeChanged() }
    }
}
