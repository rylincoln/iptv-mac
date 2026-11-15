import Foundation
import Observation
import TunerCore

/// What the guide lists. It reads the store only while the guide shows, off the main thread, and
/// lets everything go when the guide is left: a day of listings is held no longer than it is seen.
@MainActor @Observable final class GuideModel {
    /// Days listed, today first.
    static let dayCount = 7

    /// The day's events as a list, or the hours ahead as a grid of channels against time.
    enum Layout: Hashable { case events, grid }

    /// Setting it reads what the other layout shows.
    var layout: Layout {
        get { currentLayout }
        set {
            guard newValue != currentLayout else { return }
            currentLayout = newValue
            if !sections.isEmpty { sections = [] }
            if !gridRows.isEmpty { gridRows = [] }
            show(nil)
            reload(fresh: true)
        }
    }
    /// The grid's rows, for the three hours from `gridStart`. Empty until read, and in the list.
    private(set) var gridRows: [GuideGridRow] = []
    private(set) var gridStart = GuideGrid.start(now: Date())
    /// How many steps on from now the grid is moved, 0 to `GuideGrid.lastStep`. Setting it reads
    /// those hours.
    var gridSteps: Int {
        get { currentGridSteps }
        set {
            let steps = min(max(newValue, 0), GuideGrid.lastStep)
            guard steps != currentGridSteps else { return }
            currentGridSteps = steps
            reload(fresh: true)
        }
    }

    /// Whose programmes are listed. Setting it reads them.
    var filter: GuideFilter {
        get { currentFilter }
        set {
            guard newValue != currentFilter else { return }
            currentFilter = newValue
            reload(fresh: true)
        }
    }
    /// Days on from today, 0 to `dayCount - 1`. Setting it reads that day.
    var dayOffset: Int {
        get { currentDayOffset }
        set {
            guard newValue != currentDayOffset else { return }
            currentDayOffset = newValue
            reload(fresh: true)
        }
    }
    /// The day's events under their headings. Empty until read, and when there are none.
    private(set) var sections: [GuideSection] = []
    /// When `sections` were read: what "on now" was judged against.
    private(set) var readAt = Date()
    /// Nothing has been read yet for the filter and day chosen.
    private(set) var isLoading = false
    /// The store had more listings than one read takes; the latest are left out.
    private(set) var isTruncated = false
    /// The highlighted event's id, in the list.
    var selection: GuideEvent.ID? {
        get { currentSelection }
        set {
            guard newValue != currentSelection else { return }
            show(newValue.flatMap(event))
        }
    }
    /// The highlighted event: a row of the list, or one programme on one channel of the grid.
    private(set) var selected: GuideEvent?
    /// Its description, once read; the list is read without them.
    private(set) var selectedDescription: String?

    private var currentFilter = GuideFilter.sports
    private var currentDayOffset = 0
    private var currentSelection: GuideEvent.ID?
    private var currentLayout = Layout.events
    private var currentGridSteps = 0
    @ObservationIgnored private let store: Store
    @ObservationIgnored private var isShown = false
    @ObservationIgnored private var load: Task<Void, Never>?
    @ObservationIgnored private var descriptionLoad: Task<Void, Never>?

    init(store: Store) {
        self.store = store
    }

    /// The guide came into the window, or left it. It opens on today; the filter is kept.
    func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        if shown {
            currentDayOffset = 0
            currentGridSteps = 0
            reload(fresh: true)
        } else {
            load?.cancel()
            descriptionLoad?.cancel()
            sections = []
            gridRows = []
            isTruncated = false
            currentSelection = nil
            selected = nil
            selectedDescription = nil
        }
    }

    /// A minute boundary passed with the guide showing. Today's list changes with the time; another
    /// day's only at midnight, when every day moves on by one.
    func minutePassed() {
        guard isShown else { return }
        // The grid's hours move on with the time, and its line for now with every minute.
        if currentLayout == .grid || currentDayOffset == 0 || !Calendar.current.isDate(readAt, inSameDayAs: Date()) {
            reload(fresh: false)
        }
    }

    /// An import ended: programme and channel ids are new.
    func sourcesChanged() {
        if isShown { reload(fresh: false) }
    }

    /// Reads the day's listings and groups them, off the main thread. What shows stays until the read
    /// replaces it. `fresh`: for another filter or day, so the first event is then selected;
    /// otherwise the selection is kept if its event is still listed. A failed read keeps what is
    /// shown.
    private func reload(fresh: Bool) {
        load?.cancel()
        guard isShown else { return }
        if fresh { isLoading = true }
        let now = Date()
        let calendar = Calendar.current
        let filter = currentFilter
        let store = self.store
        if currentLayout == .grid {
            reloadGrid(now: now)
            return
        }
        guard let day = calendar.date(byAdding: .day, value: currentDayOffset, to: now),
              let window = GuideEvents.window(for: day, now: now, calendar: calendar)
        else { return }
        load = Task {
            let read = await Task.detached(priority: .userInitiated) { () -> (sections: [GuideSection], truncated: Bool)? in
                guard let hits = try? store.guideHits(filter, from: window.from, to: window.to) else { return nil }
                return (GuideEvents.sections(hits, day: day, now: now, calendar: calendar), hits.count >= Store.guideRowLimit)
            }.value
            guard !Task.isCancelled else { return }
            isLoading = false
            guard let read else { return }
            if read.sections != sections { sections = read.sections }
            if read.truncated != isTruncated { isTruncated = read.truncated }
            readAt = now
            if !fresh, let kept = currentSelection.flatMap(event) {
                if kept != selected { selected = kept }
                return
            }
            selection = fresh ? sections.first?.events.first?.id : nil
        }
    }

    private func event(_ id: GuideEvent.ID) -> GuideEvent? {
        for section in sections {
            if let event = section.events.first(where: { $0.id == id }) { return event }
        }
        return nil
    }

    /// The grid's three hours, read channel by channel. The programme highlighted stays so, whether
    /// or not it is still within them.
    private func reloadGrid(now: Date) {
        let start = GuideGrid.start(now: now, steps: currentGridSteps)
        let filter = currentFilter
        let store = self.store
        load = Task {
            let read = await Task.detached(priority: .userInitiated) { () -> (rows: [GuideGridRow], truncated: Bool)? in
                guard let hits = try? store.guideHits(
                    filter, from: start, to: start.addingTimeInterval(GuideGrid.length), byChannel: true)
                else { return nil }
                return (GuideGrid.rows(hits), hits.count >= Store.guideRowLimit)
            }.value
            guard !Task.isCancelled else { return }
            isLoading = false
            guard let read else { return }
            if read.rows != gridRows { gridRows = read.rows }
            if read.truncated != isTruncated { isTruncated = read.truncated }
            if start != gridStart { gridStart = start }
            readAt = now
        }
    }

    /// A programme clicked in the grid.
    func select(_ programme: ProgrammeRow, on channel: ChannelRow) {
        show(GuideEvent(programme: programme, channels: [channel]))
    }

    /// Highlights the event, or nothing, and reads its description.
    private func show(_ event: GuideEvent?) {
        descriptionLoad?.cancel()
        currentSelection = event?.id
        selected = event
        selectedDescription = nil
        guard let event else { return }
        let store = self.store
        let id = event.programme.id
        descriptionLoad = Task {
            let desc = await Task.detached(priority: .userInitiated) { (try? store.programme(id: id))?.desc }.value
            guard !Task.isCancelled, let desc, !desc.isEmpty else { return }
            selectedDescription = desc
        }
    }
}
