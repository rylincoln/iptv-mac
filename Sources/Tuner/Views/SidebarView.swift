import SwiftUI
import TunerCore

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: selection) {
            Label("Recents", systemImage: "clock").tag(ChannelSection.recents)
            Label("Favourites", systemImage: "star").tag(ChannelSection.favourites)
            Label("Sports", systemImage: "sportscourt").tag(ChannelSection.sports)
            Label("All channels", systemImage: "list.bullet").tag(ChannelSection.all)
            DisclosureGroup("Groups", isExpanded: $model.groupsExpanded) {
                ForEach(model.groups, id: \.self) { title in
                    Label(title, systemImage: "folder").tag(ChannelSection.group(title))
                }
            }
        }
    }

    private var selection: Binding<ChannelSection?> {
        Binding(
            get: { model.section },
            set: { if let section = $0 { model.section = section } })
    }
}
