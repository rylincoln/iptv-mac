import AppKit
import Foundation
import Observation
import TunerCore

/// `TunerCore.Section` under a name that does not collide with `SwiftUI.Section`.
typealias ChannelSection = TunerCore.Section

/// What the window shows and does. Store reads, store writes and imports run off the main thread;
/// the main thread only receives finished values.
@MainActor @Observable final class AppModel {
    /// Setting it reloads `rows`.
    var section: ChannelSection {
        get { currentSection }
        set {
            currentSection = newValue
            reloadRows()
        }
    }
    private(set) var rows: [ChannelRow] = []
    /// Read only while the sidebar's Groups disclosure is open.
    private(set) var groups: [String] = []
    /// The sidebar's Groups disclosure; opening it loads `groups`.
    var groupsExpanded: Bool {
        get { isGroupsExpanded }
        set {
            isGroupsExpanded = newValue
            if newValue { loadGroups() }
        }
    }
    var selectedChannelID: Int64?
    private(set) var playingChannel: ChannelRow?
    /// The programme airing on each guide channel as of `nowPlayingAt`, keyed by guide reference. One
    /// read for the whole list, reloaded on each minute boundary while the window is visible, when it
    /// becomes visible again, and after any import.
    private(set) var nowPlaying: [Int64: ProgrammeRow] = [:]
    /// When `nowPlaying` was read. Rows draw their progress bars against it, so the bars move once a
    /// minute.
    private(set) var nowPlayingAt = Date()
    /// Up to three programmes after the current one on the playing channel.
    private(set) var upNext: [ProgrammeRow] = []
    /// Text typed towards a search. A letter typed in the channel list is added to it and Escape
    /// clears it.
    var searchText = ""
    private(set) var status: PlaybackSupervisor.Status = .idle
    /// "Importing…", "4,144 channels", or a short fixed error. Never a location.
    private(set) var importMessage: String?
    private(set) var isImporting = false
    /// False when no playlist has given any channels; assumed true until the first read says otherwise.
    private(set) var hasChannels = true
    /// The URL sheet to show, if any.
    var sourcePrompt: SourceKind?

    var videoView: NSView { player.videoView }

    private var currentSection: ChannelSection = .recents
    private var isGroupsExpanded = false

    private let store: Store
    private let importer: ImportService
    private let player: VLCPlayer
    private let supervisor: PlaybackSupervisor
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var rowsLoad: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingLoad: Task<Void, Never>?
    @ObservationIgnored private var upNextLoad: Task<Void, Never>?
    /// Fires once, on the next minute boundary; exists only while the window is visible.
    @ObservationIgnored private var minuteTimer: Timer?
    @ObservationIgnored private var isWindowVisible = false

    init(store: Store, message: String? = nil) {
        self.store = store
        importer = ImportService(store: store)
        player = VLCPlayer()
        supervisor = PlaybackSupervisor(
            player: player, memory: BackgroundBufferMemory(store: store), now: Date.init)
        importMessage = message
        supervisor.onStatusChange = { [weak self] status in self?.statusChanged(status) }
        reloadRows(selectingFirst: true)
        reloadHasChannels()
        reloadNowPlaying()
    }

    /// Opens the library at ~/Library/Application Support/Tuner/tuner.sqlite. If that fails, falls back
    /// to a library that lasts for this session; nil only if neither can be opened.
    static func open() -> AppModel? {
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
           let store = try? Store(path: support.appendingPathComponent("Tuner/tuner.sqlite").path) {
            return AppModel(store: store)
        }
        guard let store = try? Store.inMemory() else { return nil }
        return AppModel(store: store, message: "Library unavailable; nothing will be saved")
    }

    // MARK: Playback

    /// Plays through the supervisor and records the channel in Recents. Asking for the channel that is
    /// already starting or playing does nothing.
    func play(_ channel: ChannelRow) {
        if playingChannel?.streamURL == channel.streamURL, status == .starting || status == .playing { return }
        if channel.guideRef != playingChannel?.guideRef { upNext = [] }  // never show another channel's
        playingChannel = channel
        reloadUpNext()
        supervisor.play(streamURL: channel.streamURL)
        let store = self.store
        Task.detached(priority: .utility) { try? store.recordWatched(channelID: channel.id, at: Date()) }
    }

    func stop() {
        supervisor.stop()
        playingChannel = nil
        upNextLoad?.cancel()
        upNext = []
    }

    /// Plays Recents entry `index` (0-based, newest first), as the store orders them.
    func playRecent(_ index: Int) {
        guard index >= 0 else { return }
        playFromRecents { recents in index < recents.count ? recents[index] : nil }
    }

    /// Plays the channel watched before the current one, by the store's Recents order; with nothing
    /// playing, the last channel watched. The current channel is skipped whether or not its own
    /// Recents entry has been written yet.
    func playPrevious() {
        let current = playingChannel?.streamURL
        playFromRecents { recents in recents.first { $0.streamURL != current } }
    }

    private func playFromRecents(_ pick: @escaping ([ChannelRow]) -> ChannelRow?) {
        let store = self.store
        Task {
            let recents = await Task.detached(priority: .userInitiated) {
                (try? store.channels(in: .recents, at: Date())) ?? []
            }.value
            if let channel = pick(recents) { play(channel) }
        }
    }

    /// The supervisor needs a tick every second whenever it is not idle, `.unavailable` included (it
    /// notices a wake from sleep through them). While idle there is no timer at all.
    private func statusChanged(_ newStatus: PlaybackSupervisor.Status) {
        status = newStatus
        if newStatus == .idle {
            ticker?.invalidate()
            ticker = nil
        } else if ticker == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.supervisor.tick() }
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)  // keeps ticking while a menu or scroll is tracking
            ticker = timer
        }
    }

    // MARK: Favourites

    /// Shows the change at once, stars and the Favourites section alike, without waiting for the write,
    /// which can sit behind an import; the Favourites section reloads once it is written.
    func toggleFavourite(_ channel: ChannelRow) {
        let on = !channel.isFavourite
        // Favourites are kept by stream URL, so every row with that URL changes.
        for index in rows.indices where rows[index].streamURL == channel.streamURL {
            rows[index].isFavourite = on
        }
        if currentSection == .favourites, !on { rows.removeAll { $0.streamURL == channel.streamURL } }
        if playingChannel?.streamURL == channel.streamURL { playingChannel?.isFavourite = on }
        let store = self.store
        Task {
            await Task.detached(priority: .userInitiated) {
                try? store.setFavourite(on, channelID: channel.id)
            }.value
            if currentSection == .favourites { reloadRows() }
        }
    }

    /// ⌘D: the selected channel.
    func toggleFavouriteOnSelection() {
        guard let id = selectedChannelID, let channel = rows.first(where: { $0.id == id }) else { return }
        toggleFavourite(channel)
    }

    // MARK: Guide

    /// The main window reports whether it is on screen. The minute timer runs only while it is; on
    /// becoming visible again, a list read in an earlier minute is read again at once.
    func windowVisibilityChanged(_ visible: Bool) {
        guard visible != isWindowVisible else { return }
        isWindowVisible = visible
        minuteTimer?.invalidate()
        minuteTimer = nil
        guard visible else { return }
        if Self.minute(of: Date()) != Self.minute(of: nowPlayingAt) { reloadNowPlaying() }
        scheduleMinuteTimer()
    }

    /// One-shot, set from the wall clock each time, so it stays on the boundary after a sleep.
    private func scheduleMinuteTimer() {
        let boundary = Date(timeIntervalSince1970: TimeInterval(Self.minute(of: Date()) + 1) * 60)
        let timer = Timer(fire: boundary, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isWindowVisible else { return }
                self.reloadNowPlaying()
                self.scheduleMinuteTimer()
            }
        }
        timer.tolerance = 1  // never early, so programmes starting on the minute are included
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    private static func minute(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / 60).rounded(.down))
    }

    /// A failed read keeps what is shown.
    private func reloadNowPlaying() {
        nowPlayingLoad?.cancel()
        let store = self.store
        let now = Date()
        nowPlayingLoad = Task {
            let loaded = await Task.detached(priority: .userInitiated) { try? store.nowPlaying(at: now) }.value
            guard !Task.isCancelled, let loaded else { return }
            nowPlaying = loaded
            nowPlayingAt = now
            reloadUpNext()
        }
    }

    /// `upcoming(after:)` includes a programme starting exactly at `after`, so it is given the current
    /// programme's stop (never earlier than now, in case the list is a minute stale), or now when
    /// nothing is airing; the current programme then never shows as Next.
    private func reloadUpNext() {
        upNextLoad?.cancel()
        guard let ref = playingChannel?.guideRef else {
            if !upNext.isEmpty { upNext = [] }
            return
        }
        let now = Date()
        let after = max(nowPlaying[ref]?.stop ?? now, now)
        let store = self.store
        upNextLoad = Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                try? store.upcoming(guideRef: ref, after: after, limit: 3)
            }.value
            guard !Task.isCancelled, let loaded, playingChannel?.guideRef == ref, loaded != upNext else { return }
            upNext = loaded
        }
    }

    // MARK: Lists

    private func loadGroups() {
        let store = self.store
        Task {
            groups = await Task.detached(priority: .userInitiated) { (try? store.groups()) ?? [] }.value
        }
    }

    private func reloadRows(selectingFirst: Bool = false) {
        rowsLoad?.cancel()
        let section = currentSection
        let store = self.store
        rowsLoad = Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                (try? store.channels(in: section, at: Date())) ?? []
            }.value
            guard !Task.isCancelled, section == currentSection else { return }
            apply(rows: loaded)
            if selectingFirst, selectedChannelID == nil { selectedChannelID = loaded.first?.id }
        }
    }

    /// Keeps the selection when the selected channel is still listed, following it by stream URL when
    /// a refresh gave it a new id.
    private func apply(rows newRows: [ChannelRow]) {
        let selected = selectedChannelID.flatMap { id in rows.first { $0.id == id } }
        rows = newRows
        refreshPlayingChannel(from: newRows)
        guard let selected, !newRows.contains(where: { $0.id == selected.id }) else { return }
        selectedChannelID = newRows.first { $0.streamURL == selected.streamURL }?.id
    }

    /// When the playing channel is listed, takes its current row: after a guide import it may have
    /// gained or changed its guide link, which the details pane follows.
    private func refreshPlayingChannel(from newRows: [ChannelRow]) {
        guard let playing = playingChannel,
              let row = newRows.first(where: { $0.streamURL == playing.streamURL }), row != playing
        else { return }
        playingChannel = row
        if row.guideRef != playing.guideRef { reloadUpNext() }
    }

    private func reloadHasChannels() {
        let store = self.store
        Task {
            hasChannels = await Task.detached(priority: .userInitiated) {
                ((try? store.sources()) ?? []).contains { $0.kind == .playlist && $0.itemCount > 0 }
            }.value
        }
    }

    // MARK: Sources

    func addPlaylist(location: String) async {
        await runImport { store, importer in
            await Self.add(.playlist, location: location, store: store, importer: importer)
        }
    }

    func addGuide(location: String) async {
        await runImport { store, importer in
            await Self.add(.guide, location: location, store: store, importer: importer)
        }
    }

    /// Playlists first, then guides, one at a time.
    func refreshAll() async {
        await runImport { store, importer in
            await Self.refreshSources(store: store, importer: importer)
        }
    }

    /// One import at a time, off the main thread; playback is never touched.
    private func runImport(_ work: @escaping @Sendable (Store, ImportService) async -> String) async {
        guard !isImporting else { return }
        isImporting = true
        importMessage = "Importing…"
        let store = self.store
        let importer = self.importer
        importMessage = await Task.detached(priority: .utility) { await work(store, importer) }.value
        isImporting = false
        reloadRows()
        reloadHasChannels()
        reloadNowPlaying()
        if isGroupsExpanded { loadGroups() }
    }

    nonisolated private static func add(
        _ kind: SourceKind, location: String, store: Store, importer: ImportService
    ) async -> String {
        guard let sourceID = try? store.addSource(kind: kind, location: location) else { return "Import failed" }
        switch await run(kind, sourceID: sourceID, importer: importer) {
        case .success(.imported(let items, _)):
            return kind == .playlist ? "\(items.formatted()) channels" : "\(items.formatted()) programmes"
        case .success(.notModified):
            return "Up to date"
        case .failure:
            return recordedError(sourceID: sourceID, store: store)
        }
    }

    nonisolated private static func refreshSources(store: Store, importer: ImportService) async -> String {
        guard let sources = try? store.sources(), !sources.isEmpty else { return "No sources" }
        var failure: String?
        for source in sources.filter({ $0.kind == .playlist }) + sources.filter({ $0.kind == .guide }) {
            if case .failure = await run(source.kind, sourceID: source.id, importer: importer), failure == nil {
                let kind = source.kind == .playlist ? "Playlist" : "Guide"
                failure = "\(kind): \(recordedError(sourceID: source.id, store: store))"
            }
        }
        if let failure { return failure }
        let channels = ((try? store.sources()) ?? []).filter { $0.kind == .playlist }.reduce(0) { $0 + $1.itemCount }
        return "\(channels.formatted()) channels"
    }

    nonisolated private static func run(
        _ kind: SourceKind, sourceID: Int64, importer: ImportService
    ) async -> Result<ImportOutcome, Error> {
        do {
            switch kind {
            case .playlist: return .success(try await importer.importPlaylist(sourceID: sourceID))
            case .guide: return .success(try await importer.importGuide(sourceID: sourceID))
            }
        } catch {
            return .failure(error)
        }
    }

    /// The short fixed message `ImportService` recorded for the source.
    nonisolated private static func recordedError(sourceID: Int64, store: Store) -> String {
        ((try? store.sources()) ?? []).first { $0.id == sourceID }?.lastError ?? "Import failed"
    }
}

/// Buffer memory whose writes run in the background: a stall during a guide import must not make the
/// main thread wait for the import's write transaction. Reads stay synchronous because the supervisor
/// needs the value at once; in WAL mode a read never waits for a writer.
private struct BackgroundBufferMemory: BufferMemory {
    let store: Store

    func bufferMs(forStreamURL streamURL: String) -> Int? {
        store.bufferMs(forStreamURL: streamURL)
    }

    func setBufferMs(_ ms: Int, forStreamURL streamURL: String) {
        let store = self.store
        Task.detached(priority: .utility) { store.setBufferMs(ms, forStreamURL: streamURL) }
    }
}
