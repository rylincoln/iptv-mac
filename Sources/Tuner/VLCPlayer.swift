import AppKit
import TunerCore
import VLCKit

/// The app's one VLCKit player, so there is never more than one stream open.
///
/// What a stream is doing is worked out by `PlaybackProgress`, from VLCKit's events and counters;
/// VLCKit's own state cannot be trusted as "is it playing".
///
/// VLCKit queues its events straight onto the main queue. Stopping a stream
/// (`libvlc_media_player_stop_async`) detaches that stream's event callbacks before it returns, so
/// every event of the stream being left is already queued when `play` starts the next, but some are
/// not yet delivered. Each `play` queues a fence behind them and ignores everything before it. After
/// the fence, nothing but an Opening is taken until this play call has opened: with this libVLC no
/// event of the stream being left gets that far, and the rule is there in case a later one lets one
/// through.
@MainActor final class VLCPlayer: NSObject, Player {
    let videoView: NSView

    private let vlcView: VLCVideoView
    private var engine: VLCMediaPlayer?       // created on the first play, so launch does not start libVLC
    private var media: VLCMedia?              // the current play call's media; nil when stopped
    private var generation = 0
    private var acceptingEvents = false
    /// The current play call's events and counters, and what they add up to.
    private var progress = PlaybackProgress(startedAt: 0)
    private var positionMs: Int64 = 0
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
        progress = PlaybackProgress(startedAt: ProcessInfo.processInfo.systemUptime)
        engine.media = media
        engine.play()
    }

    func stop() {
        generation &+= 1
        acceptingEvents = false
        if media != nil { engine?.stop() }
        media = nil
        progress = PlaybackProgress(startedAt: 0)
        positionMs = 0
    }

    var volume: Int {
        get { volumeLevel }
        set {
            volumeLevel = min(max(newValue, 0), 100)
            engine?.audio?.volume = Int32(volumeLevel)
        }
    }

    func sampleState() -> PlayerState {
        guard media != nil else { return .idle }
        // `progress` asks for the counters only once an Opening has been taken, and must not be read
        // again from inside its own call: hence `counters`, not `stats`.
        return progress.state(
            at: ProcessInfo.processInfo.systemUptime,
            counters: { counters() },
            enginePlaying: { engine?.isPlaying == true })
    }

    var stats: PlayerStats {
        // Until this play call's Opening event the media has no input, and VLCKit then returns
        // uninitialised memory as statistics. Opening, not just any event: a late event of the
        // previous stream is no proof. VLCKit 3.7 sends Opening first, within milliseconds of
        // `play`, for live streams and failing ones alike.
        progress.hasOpened ? counters() : .zero
    }

    /// The media's counters. Meaningful only after Opening (see `stats`). Even then the bitrate (a
    /// float, in kilobytes per millisecond) is sanitised, so the overlay's whole-number reading can
    /// never trap.
    private func counters() -> PlayerStats {
        guard let media else { return .zero }
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

    fileprivate func engineStateChanged() {
        guard acceptingEvents, let engine else { return }
        switch engine.state {
        case .opening: progress.take(.opening)
        case .buffering: progress.take(.buffering)
        case .playing, .esAdded, .paused: progress.take(.running)
        case .ended: progress.take(.ended)
        case .error: progress.take(.error)
        case .stopped: break  // never this play call's: `stop` turns events off before stopping
        @unknown default: break
        }
    }

    fileprivate func engineTimeChanged() {
        guard acceptingEvents, progress.hasOpened, let engine else { return }  // not the stream being left's time
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
