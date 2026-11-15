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
    /// What the search field holds. Setting it schedules a search (`scheduleSearch`).
    var searchText: String {
        get { currentSearchText }
        set {
            guard newValue != currentSearchText else { return }
            currentSearchText = newValue
            scheduleSearch()
        }
    }
    /// What `searchText` found, shown over the channel list. Nil when the text has no letters
    /// or digits to search for; empty lists when it has but nothing matches.
    private(set) var searchResults: SearchResults?
    /// The highlighted result. The first row is selected whenever new results arrive.
    var selectedResultID: SearchResultID?
    /// Bumped each time a search's results are applied, even when they equal the ones showing; not by
    /// changes to the results shown, such as a favourite. The results list scrolls to its top on it.
    private(set) var resultsGeneration = 0
    /// A later programme picked from the results. The details pane shows it in place of the playing
    /// channel's programme until a channel is played or the search is cleared.
    private(set) var chosenProgramme: ProgrammeHit?
    /// Bumped by `requestSearchField`; the window shows the search field and gives it the keyboard on
    /// each change.
    private(set) var searchFieldRequests = 0
    private(set) var status: PlaybackSupervisor.Status = .idle
    /// "Importing…", "4,144 channels", or a short fixed error. Never a location.
    private(set) var importMessage: String?
    private(set) var isImporting = false
    /// False when no playlist has given any channels; assumed true until the first read says otherwise.
    private(set) var hasChannels = true
    /// The URL sheet to show, if any.
    var sourcePrompt: SourceKind?

    var videoView: NSView { player.videoView }

    /// The stats overlay's numbers. Held apart from the model so that only the overlay watches them.
    let statsReadout = StatsReadout()
    /// ⌘I. Readings are taken only while it is on, on the supervisor's own tick.
    private(set) var showsStats = false

    private var currentSection: ChannelSection = .recents
    private var isGroupsExpanded = false
    private var currentSearchText = ""

    private let store: Store
    private let importer: ImportService
    private let player: VLCPlayer
    private let supervisor: PlaybackSupervisor
    @ObservationIgnored private var ticker: Timer?
    /// The one `ProcessInfo` activity held, if any; see `updateActivity`.
    @ObservationIgnored private var heldActivity: (kind: PlaybackActivity, token: NSObjectProtocol)?
    @ObservationIgnored private var rowsLoad: Task<Void, Never>?
    @ObservationIgnored private var nowPlayingLoad: Task<Void, Never>?
    @ObservationIgnored private var upNextLoad: Task<Void, Never>?
    /// Fires once, on the next minute boundary; exists only while the window is visible.
    @ObservationIgnored private var minuteTimer: Timer?
    @ObservationIgnored private var isWindowVisible = false
    /// Waits out the pause in typing, then runs the store query.
    @ObservationIgnored private var searchLoad: Task<Void, Never>?
    /// The store query running, if any. The next one starts only after it has finished.
    @ObservationIgnored private var searchQuery: Task<SearchResults?, Never>?
    /// The text `searchResults` were found for.
    @ObservationIgnored private var resultsText: String?
    /// Return was pressed in the search field before the results for its text were in.
    @ObservationIgnored private var activateWhenSearched = false
    /// Deletes what an import cut short by a quit or a crash left in the temporary folder. Started at
    /// launch, off the main thread; an import waits for it, so it never deletes a live import's file.
    @ObservationIgnored private var leftoverSweep: Task<Void, Never>?

    private static let searchPause: Duration = .milliseconds(80)

    init(store: Store, message: String? = nil) {
        self.store = store
        importer = ImportService(store: store, session: Self.importSession())
        player = VLCPlayer()
        supervisor = PlaybackSupervisor(
            player: player, memory: BackgroundBufferMemory(store: store), now: Date.init)
        importMessage = message
        leftoverSweep = Task.detached(priority: .utility) { ImportService.removeLeftoverFiles() }
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

    /// For playlist and guide downloads. Their URLs carry account credentials, so nothing of them may
    /// reach a disk cache or a cookie store; and a download that trickles is cut off after ten minutes
    /// rather than holding up this import, and every later one, indefinitely.
    private static func importSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }

    // MARK: Playback

    /// Plays through the supervisor and records the channel in Recents. Asking for the channel that is
    /// already starting or playing does nothing, beyond the details pane going back to it.
    func play(_ channel: ChannelRow) {
        if chosenProgramme != nil { chosenProgramme = nil }
        if playingChannel?.streamURL == channel.streamURL, status == .starting || status == .playing { return }
        if channel.guideRef != playingChannel?.guideRef { upNext = [] }  // never show another channel's
        playingChannel = channel
        reloadUpNext()
        supervisor.play(streamURL: channel.streamURL)
        if showsStats { refreshStats() }
        let store = self.store
        Task.detached(priority: .utility) {
            try? store.recordWatched(streamURL: channel.streamURL, name: channel.name, at: Date())
        }
    }

    func stop() {
        supervisor.stop()
        playingChannel = nil
        upNextLoad?.cancel()
        upNext = []
        if showsStats { refreshStats() }
    }

    /// "Try Again" on the unavailable state.
    func retry() {
        supervisor.retry()
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
        updateActivity(for: newStatus)
        if showsStats { refreshStats() }
        if newStatus == .idle {
            ticker?.invalidate()
            ticker = nil
        } else if ticker == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.supervisor.tick()
                    if self.showsStats { self.refreshStats() }
                }
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)  // keeps ticking while a menu or scroll is tracking
            ticker = timer
        }
    }

    /// Holds the activity the status needs, and no other. On a change the new one is taken before the
    /// old one is released, so there is never a moment with neither; for that instant both are held.
    /// Nothing is held while idle.
    private func updateActivity(for status: PlaybackSupervisor.Status) {
        let needed = PlaybackActivity.needed(for: status)
        guard heldActivity?.kind != needed else { return }
        let old = heldActivity
        heldActivity = needed.map { kind in
            var options: ProcessInfo.ActivityOptions = .userInitiatedAllowingIdleSystemSleep
            if kind == .keepDisplayAwake { options.insert(.idleDisplaySleepDisabled) }
            return (kind, ProcessInfo.processInfo.beginActivity(options: options, reason: "Playing a channel"))
        }
        if let old { ProcessInfo.processInfo.endActivity(old.token) }
    }

    // MARK: Stats

    func toggleStats() {
        showsStats.toggle()
        if showsStats { refreshStats() }
    }

    /// Only the host of the channel's address is ever read out of it.
    private func refreshStats() {
        let stats = player.stats
        let reading = StatsReading(
            host: playingChannel.flatMap { StreamHost.name(of: $0.streamURL) },
            inputKbps: Int(stats.inputBitrateKbps.rounded()),
            bufferMs: supervisor.currentBufferMs,
            lostPictures: stats.lostPictures,
            reconnects: supervisor.reconnectCount,
            status: status)
        if reading != statsReadout.reading { statsReadout.reading = reading }
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
        if var results = searchResults {
            for index in results.channels.indices where results.channels[index].streamURL == channel.streamURL {
                results.channels[index].isFavourite = on
            }
            for index in results.onNow.indices where results.onNow[index].channel.streamURL == channel.streamURL {
                results.onNow[index].channel.isFavourite = on
            }
            for index in results.later.indices where results.later[index].channel.streamURL == channel.streamURL {
                results.later[index].channel.isFavourite = on
            }
            searchResults = results
        }
        let store = self.store
        Task {
            await Task.detached(priority: .userInitiated) {
                try? store.setFavourite(on, streamURL: channel.streamURL, name: channel.name)
            }.value
            if currentSection == .favourites { reloadRows() }
        }
    }

    /// ⌘D: the selected channel, or the selected result's channel while results show.
    func toggleFavouriteOnSelection() {
        let channel: ChannelRow?
        if searchResults != nil {
            channel = selectedResultID.flatMap(searchResultChannel)
        } else {
            channel = selectedChannelID.flatMap { id in rows.first { $0.id == id } }
        }
        if let channel { toggleFavourite(channel) }
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

    // MARK: Search

    /// ⌘F, or a letter typed in a list.
    func requestSearchField() {
        searchFieldRequests &+= 1
    }

    /// Return in the search field: acts on the selected result. Pressed before the results for the
    /// text as typed are in, it acts on the first of those once they arrive, not on older results.
    func submitSearch() {
        if resultsText == currentSearchText {
            if let id = selectedResultID { activateSearchResult(id) }
        } else if Self.hasSearchTerms(currentSearchText) {
            activateWhenSearched = true
        }
    }

    /// Return or a double-click on a result. A programme on now, or a channel, plays that channel and
    /// the results stay up; a later programme is shown in the details pane and playback is untouched.
    func activateSearchResult(_ id: SearchResultID) {
        if case .later = id {
            if let hit = searchResultHit(id) { chosenProgramme = hit }
        } else if let channel = searchResultChannel(id) {
            play(channel)
        }
    }

    private func searchResultHit(_ id: SearchResultID) -> ProgrammeHit? {
        guard let results = searchResults else { return nil }
        switch id {
        case .onNow(let programmeID, let channelID):
            return results.onNow.first { $0.programme.id == programmeID && $0.channel.id == channelID }
        case .later(let programmeID, let channelID):
            return results.later.first { $0.programme.id == programmeID && $0.channel.id == channelID }
        case .channel:
            return nil
        }
    }

    private func searchResultChannel(_ id: SearchResultID) -> ChannelRow? {
        if case .channel(let channelID) = id { return searchResults?.channels.first { $0.id == channelID } }
        return searchResultHit(id)?.channel
    }

    /// After `searchPause` with no further change, searches the store off the main thread. A newer
    /// change cancels a search still waiting. A store query already running cannot be stopped, so the
    /// next one waits for it to finish: two never run at once. Results are applied only if the text is
    /// still the text they were found for. Text with nothing to search for clears them at once.
    private func scheduleSearch() {
        searchLoad?.cancel()
        searchLoad = nil
        activateWhenSearched = false
        let text = currentSearchText
        guard Self.hasSearchTerms(text) else {
            clearSearchResults()
            return
        }
        let store = self.store
        searchLoad = Task {
            do { try await Task.sleep(for: Self.searchPause) } catch { return }
            _ = await searchQuery?.value
            guard !Task.isCancelled else { return }
            let query = Task.detached(priority: .userInitiated) { try? store.search(text, at: Date()) }
            searchQuery = query
            let found = await query.value
            if searchQuery == query { searchQuery = nil }  // finished: nothing to wait for, nothing kept
            guard !Task.isCancelled, text == currentSearchText, let found else { return }  // a failed read keeps what is shown
            apply(found, for: text)
        }
    }

    /// The store searches runs of letters and digits, and finds nothing in text without any.
    private static func hasSearchTerms(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    private func apply(_ found: SearchResults, for text: String) {
        searchResults = found
        resultsText = text
        selectedResultID = found.firstResultID
        resultsGeneration &+= 1
        if activateWhenSearched {
            activateWhenSearched = false
            if let id = selectedResultID { activateSearchResult(id) }
        }
    }

    private func clearSearchResults() {
        resultsText = nil
        if searchResults != nil { searchResults = nil }
        if selectedResultID != nil { selectedResultID = nil }
        if chosenProgramme != nil { chosenProgramme = nil }
    }

    // MARK: Lists

    private func loadGroups() {
        let store = self.store
        Task {
            groups = await Task.detached(priority: .userInitiated) { (try? store.groups()) ?? [] }.value
        }
    }

    /// A failed read keeps what is shown. `leavingEmptyRecents`: when the section is Recents and it
    /// has nothing in it, shows All channels instead (after an import, so the first run does not land
    /// on an empty list).
    private func reloadRows(selectingFirst: Bool = false, leavingEmptyRecents: Bool = false) {
        rowsLoad?.cancel()
        let section = currentSection
        let store = self.store
        rowsLoad = Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                try? store.channels(in: section, at: Date())
            }.value
            guard !Task.isCancelled, section == currentSection, let loaded else { return }
            if leavingEmptyRecents, section == .recents, loaded.isEmpty {
                self.section = .all  // reloads
                return
            }
            apply(rows: loaded)
            if selectingFirst, selectedChannelID == nil { selectedChannelID = loaded.first?.id }
        }
    }

    /// Keeps the selection on the same channel, judged by stream URL: an import reassigns ids, so an
    /// id that is still listed may now name a different channel.
    private func apply(rows newRows: [ChannelRow]) {
        let selected = selectedChannelID.flatMap { id in rows.first { $0.id == id } }
        rows = newRows
        refreshPlayingChannel(from: newRows)
        guard let selected else { return }
        if newRows.contains(where: { $0.id == selected.id && $0.streamURL == selected.streamURL }) { return }
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

    /// A failed read keeps what is shown, so it never puts the first-run prompt over a full library.
    private func reloadHasChannels() {
        let store = self.store
        Task {
            let sources = await Task.detached(priority: .userInitiated) { try? store.sources() }.value
            guard let sources else { return }
            hasChannels = sources.contains { $0.kind == .playlist && $0.itemCount > 0 }
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
        await leftoverSweep?.value
        let store = self.store
        let importer = self.importer
        importMessage = await Task.detached(priority: .utility) { await work(store, importer) }.value
        isImporting = false
        reloadRows(leavingEmptyRecents: true)
        reloadHasChannels()
        reloadNowPlaying()
        if isGroupsExpanded { loadGroups() }
        if searchResults != nil { scheduleSearch() }
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
/// needs the value at once; in WAL mode a read never waits for a writer. The in-memory fallback library
/// has no WAL, and a read there would wait on the main thread for a whole import, so it reads nothing:
/// every channel starts at the first buffer step.
private struct BackgroundBufferMemory: BufferMemory {
    let store: Store

    func bufferMs(forStreamURL streamURL: String) -> Int? {
        store.isInMemory ? nil : store.bufferMs(forStreamURL: streamURL)
    }

    func setBufferMs(_ ms: Int, forStreamURL streamURL: String) {
        let store = self.store
        Task.detached(priority: .utility) { store.setBufferMs(ms, forStreamURL: streamURL) }
    }
}
