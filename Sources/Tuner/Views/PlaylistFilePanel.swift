import AppKit

/// Lets the owner pick a playlist file and imports it. A plain path is stored, so a refresh rereads it.
@MainActor enum PlaylistFilePanel {
    static func present(for model: AppModel) {
        let panel = NSOpenPanel()
        panel.message = "Choose a playlist file"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await model.addPlaylist(location: url.path) }
        }
    }
}
