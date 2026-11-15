import SwiftUI
import TunerCore

/// The guide, filling the pane: what is on today and through the week, as events. A programme the
/// same on several channels is one row. Along the bottom, the highlighted event in full, and the
/// corner the playing video is docked in (`PlayerPaneView` puts it there).
struct GuideView: View {
    let model: AppModel
    @Bindable var guide: GuideModel
    var focus: FocusState<PaneFocus?>.Binding
    /// The height of the toolbar lying over the pane's top edge.
    let topInset: CGFloat

    /// The docked video, and the space kept round it.
    static let dockSize = CGSize(width: 320, height: 180)
    static let dockMargin: CGFloat = 10

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, topInset)
            Divider()
            GuideEventList(model: model, guide: guide, focus: focus)
            if guide.selected != nil || model.playingChannel != nil {
                Divider()
                GuideDetails(model: model, guide: guide)
                    .frame(height: Self.dockSize.height + 2 * Self.dockMargin)
            }
        }
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $guide.filter) {
                Text("Sports").tag(GuideFilter.sports)
                Text("Favourites").tag(GuideFilter.favourites)
                Text("All").tag(GuideFilter.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("Day", selection: $guide.dayOffset) {
                ForEach(0..<GuideModel.dayCount, id: \.self) { offset in
                    Text(Self.dayName(offset, from: guide.readAt)).tag(offset)
                }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
            if guide.isTruncated {
                Text("Too many listings to show them all")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private static func dayName(_ offset: Int, from today: Date) -> String {
        switch offset {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default:
            let day = Calendar.current.date(byAdding: .day, value: offset, to: today) ?? today
            return day.formatted(.dateTime.weekday(.wide))
        }
    }
}

/// The day's events under their headings. Return or a double-click plays one that is on now; one
/// for later is only highlighted, and shows in full below.
private struct GuideEventList: View {
    let model: AppModel
    @Bindable var guide: GuideModel
    var focus: FocusState<PaneFocus?>.Binding

    var body: some View {
        let now = guide.readAt
        let today = guide.dayOffset == 0
        List(selection: $guide.selection) {
            ForEach(guide.sections) { section in
                Section(Self.title(section.kind, today: today)) {
                    ForEach(section.events) { event in
                        GuideEventRow(event: event, live: section.kind == .onNow, now: now)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, GuideEventRow.height + 8)
        .focused(focus, equals: .guide)
        // One modifier for the whole list: no per-row gestures.
        .contextMenu(forSelectionType: GuideEvent.ID.self) { ids in
            if ids.count == 1, let id = ids.first, let event = event(id) {
                ForEach(event.channels) { channel in
                    Button("Watch \(channel.name)") { model.playFromGuide(channel) }
                }
            }
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { activate(id) }
        }
        .onKeyPress(.return) {
            guard let id = guide.selection else { return .ignored }
            activate(id)
            return .handled
        }
        .overlay {
            if guide.sections.isEmpty, !guide.isLoading {
                ContentUnavailableView(
                    "No listings", systemImage: "calendar",
                    description: Text(emptyText))
            }
        }
    }

    private var emptyText: String {
        switch guide.filter {
        case .sports: return "No sport is listed for this day. Try All, or add a guide from the File menu."
        case .favourites: return "Nothing is listed for your favourite channels on this day."
        case .all: return "Add a guide from the File menu to see what is on."
        }
    }

    private func event(_ id: GuideEvent.ID) -> GuideEvent? {
        guide.selected?.id == id ? guide.selected : guide.sections.lazy.flatMap(\.events).first { $0.id == id }
    }

    /// Plays the event if it is on at this moment, on the first channel that carries it.
    private func activate(_ id: GuideEvent.ID) {
        guard let event = event(id) else { return }
        let now = Date()
        if event.programme.start <= now, now < event.programme.stop { model.playFromGuide(event.channels[0]) }
    }

    private static func title(_ kind: GuideSection.Kind, today: Bool) -> String {
        switch kind {
        case .onNow: return "On now"
        case .startingSoon: return "Starting soon"
        case .morning: return "Morning"
        case .afternoon: return "Afternoon"
        case .evening: return today ? "Tonight" : "Evening"
        }
    }
}

/// When, what and where: every row the same height, plain values only.
private struct GuideEventRow: View {
    static let height: CGFloat = 38
    static let time = Date.FormatStyle(date: .omitted, time: .shortened)

    let event: GuideEvent
    let live: Bool
    let now: Date

    var body: some View {
        let programme = event.programme
        HStack(spacing: 10) {
            Group {
                if live {
                    LiveBadge()
                } else {
                    Text(programme.start.formatted(Self.time)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(programme.title).lineLimit(1)
                    if let subTitle = programme.subTitle, !subTitle.isEmpty {
                        Text(subTitle).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Text(where_)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: Self.height)
    }

    /// "Arena 1 · also on 2 other channels · until 9:00 PM".
    private var where_: String {
        var text = event.channels[0].name
        let others = event.channels.count - 1
        if others == 1 { text += " · also on 1 other channel" }
        if others > 1 { text += " · also on \(others) other channels" }
        return text + " · until \(event.programme.stop.formatted(Self.time))"
    }
}

/// The highlighted event in full, with a way to watch each channel it is on. The trailing end is
/// left clear for the docked video while something plays.
private struct GuideDetails: View {
    let model: AppModel
    let guide: GuideModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if let event = guide.selected {
                details(event)
            }
            Spacer(minLength: 0)
            if model.playingChannel != nil {
                Color.clear.frame(width: GuideView.dockSize.width + GuideView.dockMargin)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func details(_ event: GuideEvent) -> some View {
        let programme = event.programme
        let now = guide.readAt
        let live = programme.start <= now && now < programme.stop
        return VStack(alignment: .leading, spacing: 4) {
            Text(programme.title).font(.title3.weight(.semibold)).lineLimit(1)
            if let subTitle = programme.subTitle, !subTitle.isEmpty {
                Text(subTitle).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text("\(StartTime.text(programme.start, days: StartTimeForm.Days(now: now))) – \(programme.stop.formatted(GuideEventRow.time))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if live { LiveBadge() }
            }
            if let desc = guide.selectedDescription {
                Text(desc)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
            watch(event, live: live)
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    /// One channel: a button. Several: the first is the button, and the rest are in a menu beside it.
    @ViewBuilder private func watch(_ event: GuideEvent, live: Bool) -> some View {
        let first = event.channels[0]
        HStack(spacing: 8) {
            Button(live ? "Watch on \(first.name)" : "Watch \(first.name) Now") { model.playFromGuide(first) }
                .buttonStyle(.borderedProminent)
            if event.channels.count > 1 {
                Menu("Other Channels") {
                    ForEach(event.channels.dropFirst()) { channel in
                        Button(channel.name) { model.playFromGuide(channel) }
                    }
                }
                .fixedSize()
            }
        }
    }
}
