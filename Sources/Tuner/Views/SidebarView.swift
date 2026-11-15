import SwiftUI
import TunerCore

struct SidebarView: View {
    @Bindable var model: AppModel
    var focus: FocusState<PaneFocus?>.Binding

    var body: some View {
        List(selection: selection(
            guide: model.showsGuide, unselected: model.showsSearchResults || !model.showsChannelList)
        ) {
            Label("Recents", systemImage: "clock").tag(SidebarItem.section(.recents))
            Label("Favourites", systemImage: "star").tag(SidebarItem.section(.favourites))
            Label("Sports", systemImage: "sportscourt").tag(SidebarItem.section(.sports))
            Label("Guide", systemImage: "calendar.day.timeline.left").tag(SidebarItem.guide)
            Label("All channels", systemImage: "list.bullet").tag(SidebarItem.section(.all))
            DisclosureGroup("Groups", isExpanded: $model.groupsExpanded) {
                ForEach(model.groups, id: \.self) { title in
                    Label(title, systemImage: "folder").tag(SidebarItem.section(.group(title)))
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            SearchField(model: model, focus: focus)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
    }

    /// Choosing a section leaves the search, so the section's channels show. While results show, no
    /// section is selected (they are not the section's), so a click on any section, the one under
    /// the results included, leaves the search. Likewise while the channel list is put away: a click
    /// on any section, the one last shown included, brings the list back.
    /// The guide is a row among them: it takes the pane, and is the row selected while it shows.
    private func selection(guide: Bool, unselected: Bool) -> Binding<SidebarItem?> {
        Binding(
            get: { guide ? .guide : unselected ? nil : .section(model.section) },
            set: {
                switch $0 {
                case nil:
                    break
                case .guide:
                    model.searchText = ""
                    model.send(.guideChosen)
                case .section(let section):
                    model.searchText = ""
                    model.send(.sectionChosen)
                    if section != model.section { model.section = section }
                }
            })
    }
}

/// A row of the sidebar: a section of channels, or the guide.
private enum SidebarItem: Hashable {
    case section(ChannelSection)
    case guide
}

/// The search field: what is typed is searched as it is typed. Return acts on the selected result and
/// Down moves into the results.
///
/// A list hands over typed letters by adding them to the search text and focusing the field. AppKit
/// selects a field's text when it gains focus, so the next letter would replace the ones handed over;
/// so whenever the text changed while the field was away, the insertion point goes to the end
/// instead. Gaining focus with the text unchanged (⌘F, a click) behaves as any Mac field does.
private struct SearchField: View {
    @Bindable var model: AppModel
    var focus: FocusState<PaneFocus?>.Binding
    @State private var selection: TextSelection?
    /// The text when the field last lost focus; "" once the text is cleared.
    @State private var textWhenLeft = ""

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $model.searchText, selection: $selection)
                .textFieldStyle(.plain)
                .focused(focus, equals: .search)
                .onSubmit { model.submitSearch() }
                .onKeyPress(.downArrow) {
                    guard let results = model.searchResults, !results.isEmpty else { return .ignored }
                    focus.wrappedValue = .channelList
                    return .handled
                }
                .onChange(of: focus.wrappedValue) { old, new in
                    if old == .search { textWhenLeft = model.searchText }
                    if new == .search { model.send(.searchFieldFocused) }  // a click on the field brings the list back
                    if new == .search, old != .search, model.searchText != textWhenLeft {
                        selection = TextSelection(insertionPoint: model.searchText.endIndex)
                    }
                }
                .onChange(of: model.searchText) { _, text in
                    if text.isEmpty { textWhenLeft = "" }
                }
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }
}
