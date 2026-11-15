import SwiftUI
import TunerCore

/// The guide, filling the pane: what is on today and through the week, as a list of events (a
/// programme the same on several channels is one row) or as a grid of channels against time. Along
/// the bottom, the highlighted programme in full, and the corner the playing video is docked in
/// (`PlayerPaneView` puts it there).
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
            switch guide.layout {
            case .events: GuideEventList(model: model, guide: guide, focus: focus)
            case .grid: GuideGridView(model: model, guide: guide)
            }
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
            switch guide.layout {
            case .events:
                Picker("Day", selection: $guide.dayOffset) {
                    ForEach(0..<GuideModel.dayCount, id: \.self) { offset in
                        Text(Self.dayName(offset, from: guide.readAt)).tag(offset)
                    }
                }
                .labelsHidden()
                .fixedSize()
            case .grid:
                ControlGroup {
                    Button("Earlier", systemImage: "chevron.left") { guide.gridSteps -= 1 }
                        .disabled(guide.gridSteps == 0)
                    Button("Now") { guide.gridSteps = 0 }
                        .disabled(guide.gridSteps == 0)
                    Button("Later", systemImage: "chevron.right") { guide.gridSteps += 1 }
                        .disabled(guide.gridSteps == GuideGrid.lastStep)
                }
                .fixedSize()
            }
            Spacer()
            if guide.isTruncated {
                Text("Too many listings to show them all")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Picker("Layout", selection: $guide.layout) {
                Label("Events", systemImage: "list.bullet").tag(GuideModel.Layout.events)
                Label("Grid", systemImage: "tablecells").tag(GuideModel.Layout.grid)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .labelsHidden()
            .fixedSize()
            .help("Events or grid")
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

/// Channels down, time across: three hours, moved by the buttons above. A click highlights a
/// programme, which then shows in full below; a double-click plays one that is on now. Rows are
/// built only as they scroll into view.
private struct GuideGridView: View {
    let model: AppModel
    let guide: GuideModel

    private static let channelWidth: CGFloat = 170
    private static let rowHeight: CGFloat = 38
    private static let margin: CGFloat = 16
    private static let day = Date.FormatStyle(date: .omitted, time: .shortened).weekday(.abbreviated)

    var body: some View {
        GeometryReader { proxy in
            let track = max(proxy.size.width - Self.channelWidth - 2 * Self.margin, 120)
            let start = guide.gridStart
            let now = guide.readAt
            // Where now falls across the hours shown, if it does.
            let nowAt = GuideGrid.span(start: start, stop: now, gridStart: start).flatMap { $0.to < 1 ? $0.to : nil }
            let selected = guide.selected.map { Cell(programme: $0.programme.id, channel: $0.channels[0].id) }
            VStack(spacing: 0) {
                times(start: start, track: track, today: Calendar.current.isDate(start, inSameDayAs: now))
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(guide.gridRows) { row in
                            GuideGridRowView(
                                row: row, start: start, now: now, nowAt: nowAt, track: track,
                                selected: selected?.channel == row.channel.id ? selected?.programme : nil,
                                select: { guide.select($0, on: row.channel) },
                                play: { programme in
                                    let at = Date()
                                    if programme.start <= at, at < programme.stop { model.playFromGuide(row.channel) }
                                })
                        }
                    }
                    .padding(.horizontal, Self.margin)
                }
            }
        }
        .overlay {
            if guide.gridRows.isEmpty, !guide.isLoading {
                ContentUnavailableView(
                    "No listings", systemImage: "calendar",
                    description: Text("Nothing is listed for these channels in these hours."))
            }
        }
    }

    private struct Cell: Equatable {
        var programme: Int64
        var channel: Int64
    }

    /// The half hours across the top, each over its place in the rows.
    private func times(start: Date, track: CGFloat, today: Bool) -> some View {
        let halves = Int(GuideGrid.length / 1800)
        return HStack(spacing: 0) {
            Color.clear.frame(width: Self.channelWidth, height: 1)
            ZStack(alignment: .topLeading) {
                ForEach(0..<halves, id: \.self) { index in
                    let time = start.addingTimeInterval(Double(index) * 1800)
                    Text(time.formatted(index == 0 && !today ? Self.day : GuideEventRow.time))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: track * CGFloat(index) / CGFloat(halves))
                }
            }
            .frame(width: track, alignment: .leading)
        }
        .padding(.horizontal, Self.margin)
        .padding(.vertical, 6)
    }

    /// One channel: its name, then its programmes laid along the hours, with a line where now is.
    private struct GuideGridRowView: View {
        let row: GuideGridRow
        let start: Date
        let now: Date
        let nowAt: Double?
        let track: CGFloat
        /// The highlighted programme, if it is on this channel.
        let selected: Int64?
        let select: (ProgrammeRow) -> Void
        let play: (ProgrammeRow) -> Void

        var body: some View {
            HStack(spacing: 0) {
                Text(row.channel.name)
                    .lineLimit(1)
                    .padding(.trailing, 8)
                    .frame(width: GuideGridView.channelWidth, alignment: .leading)
                ZStack(alignment: .topLeading) {
                    ForEach(row.programmes) { programme in
                        if let span = GuideGrid.span(start: programme.start, stop: programme.stop, gridStart: start) {
                            cell(programme, width: track * CGFloat(span.to - span.from))
                                .offset(x: track * CGFloat(span.from))
                        }
                    }
                    if let nowAt {
                        Rectangle()
                            .fill(.red)
                            .frame(width: 1, height: GuideGridView.rowHeight)
                            .offset(x: track * CGFloat(nowAt))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: track, height: GuideGridView.rowHeight, alignment: .topLeading)
            }
        }

        private func cell(_ programme: ProgrammeRow, width: CGFloat) -> some View {
            let live = programme.start <= now && now < programme.stop
            let chosen = programme.id == selected
            return Text(width > 34 ? programme.title : "")
                .font(.callout)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(width: max(width - 2, 1), height: GuideGridView.rowHeight - 4, alignment: .leading)
                .background(
                    .white.opacity(chosen ? 0.32 : live ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { play(programme) }
                .simultaneousGesture(TapGesture().onEnded { select(programme) })
                .padding(.vertical, 2)
                .accessibilityElement()
                .accessibilityLabel("\(programme.title), \(programme.start.formatted(GuideEventRow.time)) on \(row.channel.name)")
                .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { select(programme) }
        }
    }
}
