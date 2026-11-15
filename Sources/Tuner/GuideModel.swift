import Foundation
import Observation
import TunerCore

/// What the guide lists. It reads the store only while the guide shows, off the main thread, and
/// lets everything go when the guide is left: a day of listings is held no longer than it is seen.
@MainActor @Observable final class GuideModel {
    /// Days listed, today first.
    static let dayCount = 7

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
    /// The highlighted event's id.
    var selection: GuideEvent.ID? {
        get { currentSelection }
        set {
            guard newValue != currentSelection else { return }
            currentSelection = newValue
            selectionChanged()
        }
    }
    /// The highlighted event.
    private(set) var selected: GuideEvent?
    /// Its description, once read; the list is read without them.
    private(set) var selectedDescription: String?

    private var currentFilter = GuideFilter.sports
    private var currentDayOffset = 0
    private var currentSelection: GuideEvent.ID?
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
            reload(fresh: true)
        } else {
            load?.cancel()
            descriptionLoad?.cancel()
            sections = []
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
        if currentDayOffset == 0 || !Calendar.current.isDate(readAt, inSameDayAs: Date()) { reload(fresh: false) }
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

    private func selectionChanged() {
        descriptionLoad?.cancel()
        let event = currentSelection.flatMap(event)
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
