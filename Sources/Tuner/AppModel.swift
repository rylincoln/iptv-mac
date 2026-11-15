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
            send(.sectionChosen)
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
            if !newValue.isEmpty { send(.searchTyped) }
        }
    }
    /// What `searchText` found, shown over the channel list. Nil when the text has no letters
    /// or digits to search for; empty lists when it has but nothing matches.
    private(set) var searchResults: SearchResults?
    /// Whether results (or "No results") show. Changes only when a search starts or ends, so a view
    /// that needs no more than this is not updated for every new set of results.
    private(set) var showsSearchResults = false
    /// The highlighted result. The first row is selected whenever a search's results arrive; the
    /// minute's refresh of them keeps the selection where it can.
    var selectedResultID: SearchResultID?
    /// Bumped each time a search's results are applied, even when they equal the ones showing; not by
    /// changes to the results shown, such as a favourite or the minute's refresh. The results list
    /// scrolls to its top on it.
    private(set) var resultsGeneration = 0
    /// A later programme picked from the results. The details pane shows it in place of the playing
    /// channel's programme until a channel is played or the search is cleared.
    private(set) var chosenProgramme: ProgrammeHit?
    /// What shows around the video: the channel list over it, the video full screen. Changed only
    /// by `send`, which applies `WindowState`'s rules.
    private(set) var window = WindowState()
    var showsChannelList: Bool { window.showsChannelList }
    var videoFullScreen: Bool { window.videoFullScreen }
    var pictureInPicture: Bool { window.pictureInPicture }
    var showsGuide: Bool { window.showsGuide }
    /// What the guide lists; it holds listings only while the guide shows.
    let guide: GuideModel
    /// Bumped when `send` leaves the window something to do; it takes them with `takeWindowOutcomes`.
    private(set) var windowOutcomeCount = 0
    @ObservationIgnored private var windowOutcomes: [WindowState.Outcome] = []
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
    /// ⌘I. Readings are taken only while it is on and the window is on screen: one after each of the
    /// supervisor's own ticks, and one when a command changes the playback.
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
    /// The section `rows` were read for; nil until the first read is applied.
    @ObservationIgnored private var rowsSection: ChannelSection?
    /// The time `rows` were read for. The Sports section depends on it, and is not read on the minute
    /// while search results cover it; it is read when they go, if a minute has passed since.
    @ObservationIgnored private var rowsReadAt = Date.distantPast
    @ObservationIgnored private var nowPlayingLoad: Task<Void, Never>?
    @ObservationIgnored private var upNextLoad: Task<Void, Never>?
    /// A channel asked for by its place in Recents (⌘1…⌘9, ⌘[), while Recents is read.
    @ObservationIgnored private var recentsPlay: Task<Void, Never>?
    /// Favourites are shown changed before they are written, and a write can wait behind an import. A
    /// store read made meanwhile can find the store without the change and would show it undone: the
    /// minute's reads wait for the writes; any other read that overlapped one is made again once the
    /// writes have ended, and meanwhile is shown only if it is of something new (a section just
    /// chosen, text just typed), never in place of a list or results already shown.
    @ObservationIgnored private var favouriteWrites = OptimisticWrites<StarRead>()
    /// Fires once, on the next minute boundary; exists only while the window is visible.
    @ObservationIgnored private var minuteTimer: Timer?
    @ObservationIgnored private var isWindowVisible = false
    /// Runs the searches the field asks for: the pause in typing, one store query at a time, only
    /// the latest text's results delivered.
    @ObservationIgnored private let search = LatestSearch<SearchRead>()
    /// The text `searchResults` were found for.
    @ObservationIgnored private var resultsText: String?
    /// Return was pressed in the search field before the results for its text were in.
    @ObservationIgnored private var activateWhenSearched = false
    /// Deletes what an import cut short by a quit or a crash left in the temporary folder. Started at
    /// launch, off the main thread; an import waits for it, so it never deletes a live import's file.
    @ObservationIgnored private var leftoverSweep: Task<Void, Never>?

    private static let searchPause: Duration = .milliseconds(80)

    /// The reads that show stars: the channel list, the search results, and one stream's star, read
    /// back once its writes have ended.
    private enum StarRead: Hashable, Sendable { case rows, search, favourite(streamURL: String) }

    init(store: Store, message: String? = nil) {
        self.store = store
        importer = ImportService(store: store, session: Self.importSession())
        player = VLCPlayer()
        guide = GuideModel(store: store)
        // Timed by a clock that setting the wall clock cannot move, and that counts time asleep, so a
        // sleep still shows as a gap. Used for nothing else: guide times, Recents and imports read the
        // wall clock (`Date()`), since these dates drift from it once it is set.
        let clock = ContinuousDate()
        supervisor = PlaybackSupervisor(
            player: player, memory: BackgroundBufferMemory(store: store), now: { clock.now() })
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
    /// already starting or playing does nothing, beyond the details pane going back to it. A Recents
    /// entry asked for earlier and still being read is dropped: the last request wins.
    func play(_ channel: ChannelRow) {
        cancelRecentsPlay()
        send(.played)
        if chosenProgramme != nil { chosenProgramme = nil }
        if playingChannel?.streamURL == channel.streamURL, status == .starting || status == .playing { return }
        if channel.guideRef != playingChannel?.guideRef { upNext = [] }  // never show another channel's
        playingChannel = channel
        reloadUpNext()
        supervisor.play(streamURL: channel.streamURL)
        refreshStatsIfSeen()
        let store = self.store
        Task.detached(priority: .utility) {
            try? store.recordWatched(streamURL: channel.streamURL, name: channel.name, at: Date())
        }
    }

    func stop() {
        cancelRecentsPlay()
        send(.stopped)
        supervisor.stop()
        playingChannel = nil
        upNextLoad?.cancel()
        upNext = []
        refreshStatsIfSeen()
    }

    /// Return or a double-click on a programme in the guide that is on now: plays it and goes back
    /// to the video.
    func playFromGuide(_ channel: ChannelRow) {
        play(channel)
        send(.leaveGuide)
    }

    /// "Try Again" on the unavailable state. A Recents entry asked for earlier and still being read is
    /// dropped, as by any later request.
    func retry() {
        cancelRecentsPlay()
        supervisor.retry()
        refreshStatsIfSeen()
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

    /// Reads Recents off the main thread, then plays what `pick` chooses from them, unless a later
    /// request (another of these, a channel played, Stop) came first.
    private func playFromRecents(_ pick: @escaping ([ChannelRow]) -> ChannelRow?) {
        cancelRecentsPlay()
        let store = self.store
        recentsPlay = Task {
            let recents = await Task.detached(priority: .userInitiated) {
                (try? store.channels(in: .recents, at: Date())) ?? []
            }.value
            guard !Task.isCancelled else { return }
            recentsPlay = nil  // still the latest request, and finished
            if let channel = pick(recents) { play(channel) }
        }
    }

    private func cancelRecentsPlay() {
        recentsPlay?.cancel()
        recentsPlay = nil
    }

    /// The supervisor needs a tick every second whenever it is not idle, `.unavailable` included (it
    /// notices a wake from sleep through them). While idle there is no timer at all. The stats are
    /// read once a tick, after it, and by each command that changes the status (`play`, `stop`,
    /// `retry`), not here, so a tick that changes the status is not read twice.
    private func statusChanged(_ newStatus: PlaybackSupervisor.Status) {
        status = newStatus
        updateActivity(for: newStatus)
        if newStatus == .idle {
            ticker?.invalidate()
            ticker = nil
        } else if ticker == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.supervisor.tick()
                    self.refreshStatsIfSeen()
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
        refreshStatsIfSeen()
    }

    /// Takes a reading only when it can be seen: the overlay on, in a window on screen. A window that
    /// comes back on screen takes one at once (`windowVisibilityChanged`).
    private func refreshStatsIfSeen() {
        if showsStats, isWindowVisible { refreshStats() }
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
    /// which can sit behind an import; until every such write has ended, reads of the store wait or are
    /// made again (`favouriteWrites`). Every star changed is read back from the store once every write
    /// has ended, written or not, so the stars end as the store holds them: whatever order queued
    /// writes for one stream ran in, and when a write failed (not simply put back: when two writes for
    /// a stream both fail, putting each back leaves the star the wrong way).
    func toggleFavourite(_ channel: ChannelRow) {
        let on = !channel.isFavourite
        showFavourite(on, streamURL: channel.streamURL)
        favouriteWrites.begin()
        favouriteWrites.hold(.favourite(streamURL: channel.streamURL))
        let store = self.store
        Task {
            await Task.detached(priority: .userInitiated) {
                _ = try? store.setFavourite(on, streamURL: channel.streamURL, name: channel.name)
            }.value
            if let reads = favouriteWrites.end() { readAfterFavouriteWrites(reads) }
        }
    }

    /// Every favourite write has ended. The reads that may have missed one are made again, the stars
    /// changed are read back, and the Favourites section is read again while it is the section chosen:
    /// a channel starred elsewhere shows there only once read, and a row whose removal could not be
    /// written comes back.
    private func readAfterFavouriteWrites(_ reads: Set<StarRead>) {
        if reads.contains(.rows) || currentSection == .favourites { reloadRows() }
        if reads.contains(.search) { refreshSearchResults() }
        let changed = reads.compactMap { read -> String? in
            if case .favourite(let streamURL) = read { return streamURL }
            return nil
        }
        if !changed.isEmpty { readBackFavourites(of: changed) }
    }

    /// Shows each stream's star as the store has it, read off the main thread. A star changed again
    /// while it was read is left to that change, and read back after it if its write fails too.
    private func readBackFavourites(of streamURLs: [String]) {
        let store = self.store
        let ticket = favouriteWrites.ticket
        Task {
            let stored = await Task.detached(priority: .userInitiated) {
                streamURLs.map { streamURL in (streamURL, try? store.isFavourite(streamURL: streamURL)) }
            }.value
            for (streamURL, on) in stored {
                switch favouriteWrites.check(.favourite(streamURL: streamURL), since: ticket) {
                case .current: if let on { showFavourite(on, streamURL: streamURL) }  // a failed read changes nothing
                case .heldUntilWritten: break  // read back once the writes have ended
                case .readAgainNow: readBackFavourites(of: [streamURL])
                }
            }
        }
    }

    /// Stars or unstars every row shown with the stream URL: the list, the playing channel and the
    /// search results. Favourites are kept by stream URL, so every row with that URL changes. Unstarred
    /// rows leave the Favourites section at once; a selection among them moves to the row that takes
    /// its place, so ⌘D and Return still act on a highlighted row.
    /// Only what differs is assigned, so a star read back unchanged updates nothing on screen.
    private func showFavourite(_ on: Bool, streamURL: String) {
        let isStream: (ChannelRow) -> Bool = { $0.streamURL == streamURL }
        if currentSection == .favourites, !on {
            if rows.contains(where: isStream) {
                let selection = ListSelection.afterRemoving(from: rows, where: isStream, selected: selectedChannelID)
                rows.removeAll(where: isStream)
                if selection != selectedChannelID { selectedChannelID = selection }
            }
        } else {
            for index in rows.indices where isStream(rows[index]) && rows[index].isFavourite != on {
                rows[index].isFavourite = on
            }
        }
        if let playing = playingChannel, isStream(playing), playing.isFavourite != on {
            playingChannel?.isFavourite = on
        }
        if var results = searchResults {
            var changed = false
            for index in results.channels.indices
            where isStream(results.channels[index]) && results.channels[index].isFavourite != on {
                results.channels[index].isFavourite = on
                changed = true
            }
            for index in results.onNow.indices
            where isStream(results.onNow[index].channel) && results.onNow[index].channel.isFavourite != on {
                results.onNow[index].channel.isFavourite = on
                changed = true
            }
            for index in results.later.indices
            where isStream(results.later[index].channel) && results.later[index].channel.isFavourite != on {
                results.later[index].channel.isFavourite = on
                changed = true
            }
            if changed { searchResults = results }
        }
    }

    /// ⌘D: the selected channel, or the selected result's channel while results show.
    func toggleFavouriteOnSelection() {
        guard !showsGuide else { return }  // the lists it acts on are out of sight
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
    /// becoming visible again, what was read in an earlier minute is read again at once.
    func windowVisibilityChanged(_ visible: Bool) {
        guard visible != isWindowVisible else { return }
        isWindowVisible = visible
        minuteTimer?.invalidate()
        minuteTimer = nil
        guard visible else { return }
        if Self.minute(of: Date()) != Self.minute(of: nowPlayingAt) { reloadForNewMinute() }
        scheduleMinuteTimer()
        refreshStatsIfSeen()  // none were read while it was off screen
    }

    /// One-shot, set from the wall clock each time, so it stays on the boundary after a sleep.
    private func scheduleMinuteTimer() {
        let boundary = Date(timeIntervalSince1970: TimeInterval(Self.minute(of: Date()) + 1) * 60)
        let timer = Timer(fire: boundary, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isWindowVisible else { return }
                self.reloadForNewMinute()
                self.scheduleMinuteTimer()
            }
        }
        timer.tolerance = 1  // never early, so programmes starting on the minute are included
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    /// Whole minutes since 1970, rounded down for any time after it. Never traps, whatever the date: the
    /// seconds come from the store's own conversion, which is held far inside `Int64`.
    private static func minute(of date: Date) -> Int64 {
        Store.unixSeconds(date, rounding: .down) / 60
    }

    /// What depends on the time, read again on the minute while the window is visible: what is on now,
    /// the Sports section's channels when it is the section shown (it lists the channels with a sport
    /// on now; covered by search results, it is read when they go), and the search results while they
    /// show. A read that finds what is shown changes nothing on screen. The reads that show stars wait
    /// while a favourite is still being written, and are made once it is (`favouriteWrites`).
    private func reloadForNewMinute() {
        reloadNowPlaying()
        guide.minutePassed()
        if searchResults == nil {
            if currentSection == .sports, favouriteWrites.mayRead(.rows) { reloadRows() }
        } else if favouriteWrites.mayRead(.search) {
            refreshSearchResults()
        }
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

    // MARK: Window

    /// Tells the window's state what happened. What it changes shows at once; anything more the
    /// window must do (move the keyboard, show the search field) waits in `windowOutcomes`.
    func send(_ event: WindowState.Event) {
        var next = window
        let outcome = next.handle(event, playing: playingChannel != nil)
        let guideChanged = next.showsGuide != window.showsGuide
        if next != window { window = next }
        if guideChanged { guide.setShown(next.showsGuide) }
        if outcome != WindowState.Outcome() {
            windowOutcomes.append(outcome)
            windowOutcomeCount &+= 1
        }
    }

    func takeWindowOutcomes() -> [WindowState.Outcome] {
        defer { windowOutcomes = [] }
        return windowOutcomes
    }

    // MARK: Search

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

    /// After `searchPause` with no further change, searches the store off the main thread
    /// (`LatestSearch`). Text with nothing to search for clears the results at once.
    private func scheduleSearch() {
        activateWhenSearched = false
        let text = currentSearchText
        guard Self.hasSearchTerms(text) else {
            search.cancel()
            clearSearchResults()
            return
        }
        search.search(text, after: Self.searchPause, read: searchRead(text, priority: .userInitiated)) { [weak self] read in
            guard let self else { return }
            apply(read.results, for: text)
            if favouriteWrites.check(.search, since: read.ticket) == .readAgainNow { refreshSearchResults() }
        }
    }

    /// On the minute: the results showing are found again for their text, so a programme that has
    /// ended leaves On now and one that has begun moves up from Later. Results equal to those showing
    /// change nothing. Others replace them with the selection kept where it can be
    /// (`SearchResults.selection(following:in:)`) and the list left where it is scrolled. While a
    /// search waits or runs this does nothing (`LatestSearch.refresh`): that search reads the store
    /// afresh anyway, and it may be the one an import starts once it has reassigned every id, which
    /// a refresh, keeping the selection by the old ids, must not cancel.
    private func refreshSearchResults() {
        guard searchResults != nil, let text = resultsText, text == currentSearchText else { return }
        search.refresh(text, read: searchRead(text, priority: .utility)) { [weak self] read in
            guard let self, text == resultsText else { return }
            // Not shown if it may have missed a favourite written meanwhile; read again after the write.
            let use = favouriteWrites.use(.search, since: read.ticket, replacingShown: true)
            if use.show, let old = searchResults, read.results != old {
                searchResults = read.results
                let selection = read.results.selection(following: selectedResultID, in: old)
                if selection != selectedResultID { selectedResultID = selection }
            }
            if use.readAgain { refreshSearchResults() }
        }
    }

    /// One store search, with the favourite-writes ticket taken as it began. A failed read is nil,
    /// which keeps what is shown.
    private struct SearchRead: Sendable {
        var results: SearchResults
        var ticket: OptimisticWrites<StarRead>.Ticket
    }

    private func searchRead(_ text: String, priority: TaskPriority) -> LatestSearch<SearchRead>.Read {
        { [weak self] in
            guard let self else { return nil }
            let ticket = favouriteWrites.ticket
            let store = self.store
            let results = await Task.detached(priority: priority) { try? store.search(text, at: Date()) }.value
            return results.map { SearchRead(results: $0, ticket: ticket) }
        }
    }

    /// The store searches runs of letters and digits, and finds nothing in text without any.
    private static func hasSearchTerms(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    private func apply(_ found: SearchResults, for text: String) {
        searchResults = found
        if !showsSearchResults { showsSearchResults = true }
        resultsText = text
        selectedResultID = found.firstResultID
        resultsGeneration &+= 1
        if activateWhenSearched {
            activateWhenSearched = false
            if let id = selectedResultID { activateSearchResult(id) }
        }
    }

    /// A Sports list left covered across a minute boundary is read now, as the results go.
    private func clearSearchResults() {
        resultsText = nil
        if searchResults != nil {
            searchResults = nil
            if currentSection == .sports, Self.minute(of: Date()) != Self.minute(of: rowsReadAt),
               favouriteWrites.mayRead(.rows) {
                reloadRows()
            }
        }
        if showsSearchResults { showsSearchResults = false }
        if selectedResultID != nil { selectedResultID = nil }
        if chosenProgramme != nil { chosenProgramme = nil }
    }

    // MARK: Lists

    /// A failed read keeps what is shown.
    private func loadGroups() {
        let store = self.store
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { try? store.groups() }.value
            guard let loaded, loaded != groups else { return }
            groups = loaded
        }
    }

    /// A failed read keeps what is shown when that is this section's own rows, read earlier. Rows of
    /// the section shown before are never left under this one's title: the section shows empty
    /// instead. `leavingEmptyRecents`: when the section is Recents and it has nothing in it, shows All
    /// channels instead (after an import, so the first run does not land on an empty list).
    private func reloadRows(selectingFirst: Bool = false, leavingEmptyRecents: Bool = false) {
        rowsLoad?.cancel()
        let section = currentSection
        let store = self.store
        let ticket = favouriteWrites.ticket
        let now = Date()
        rowsLoad = Task {
            let loaded = await Task.detached(priority: .userInitiated) {
                try? store.channels(in: section, at: now)
            }.value
            guard !Task.isCancelled, section == currentSection else { return }
            guard let loaded else {
                if rowsSection != section { apply(rows: [], of: section) }
                return
            }
            if leavingEmptyRecents, section == .recents, loaded.isEmpty {
                self.section = .all  // reloads
                return
            }
            // The section shown, read again, is not replaced by a read that may have missed a favourite
            // written meanwhile: that would put the star back. It is read again after the write.
            let use = favouriteWrites.use(.rows, since: ticket, replacingShown: rowsSection == section)
            if use.show {
                apply(rows: loaded, of: section)
                rowsReadAt = now
                if selectingFirst, selectedChannelID == nil { selectedChannelID = loaded.first?.id }
            }
            if use.readAgain { reloadRows(selectingFirst: selectingFirst, leavingEmptyRecents: leavingEmptyRecents) }
        }
    }

    /// Keeps the selection on the same channel, judged by stream URL: an import reassigns ids, so an
    /// id that is still listed may now name a different channel. When the section is read again and
    /// the channel has left it (its sport over, say), the selection moves to the channel that takes
    /// its place, as when a favourite is removed. Rows equal to those shown are not assigned, so a
    /// list read again unchanged is not updated.
    private func apply(rows newRows: [ChannelRow], of section: ChannelSection) {
        let oldRows = rows
        let readAgain = rowsSection == section
        rowsSection = section
        let selected = selectedChannelID.flatMap { id in oldRows.first { $0.id == id } }
        if newRows != oldRows { rows = newRows }
        refreshPlayingChannel(from: newRows)
        guard let selected else { return }
        if newRows.contains(where: { $0.id == selected.id && $0.streamURL == selected.streamURL }) { return }
        if let same = newRows.first(where: { $0.streamURL == selected.streamURL }) {
            selectedChannelID = same.id
        } else if readAgain {
            let listed = Set(newRows.map(\.streamURL))
            let next = ListSelection.afterRemoving(
                from: oldRows, where: { !listed.contains($0.streamURL) }, selected: selected.id)
            let nextURL = next.flatMap { id in oldRows.first { $0.id == id } }?.streamURL
            selectedChannelID = nextURL.flatMap { url in newRows.first { $0.streamURL == url } }?.id
        } else {
            selectedChannelID = nil
        }
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
        guide.sourcesChanged()
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
        case .failure(let error):
            let text = failureText(error, sourceID: sourceID, store: store)
            return text.prefix(1).uppercased() + text.dropFirst()
        }
    }

    nonisolated private static func refreshSources(store: Store, importer: ImportService) async -> String {
        guard let sources = try? store.sources(), !sources.isEmpty else { return "No sources" }
        var failure: String?
        for source in sources.filter({ $0.kind == .playlist }) + sources.filter({ $0.kind == .guide }) {
            if case .failure(let error) = await run(source.kind, sourceID: source.id, importer: importer),
               failure == nil {
                let kind = source.kind == .playlist ? "Playlist" : "Guide"
                failure = "\(kind): \(failureText(error, sourceID: source.id, store: store))"
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

    /// What to show for a failed import. A provider's "too many requests" says when to try again:
    /// until then a refresh does not ask the provider at all.
    nonisolated private static func failureText(_ error: Error, sourceID: Int64, store: Store) -> String {
        guard case ImportError.rateLimited(let until) = error else {
            return recordedError(sourceID: sourceID, store: store)
        }
        let sameDay = Calendar.current.isDate(until, inSameDayAs: Date())
        let when = until.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened)
        return "provider is limiting requests, try again after \(when)"
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
