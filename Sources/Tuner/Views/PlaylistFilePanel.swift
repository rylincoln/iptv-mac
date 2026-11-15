import AppKit

/// Lets the owner pick a playlist file and imports it. A plain path is stored, so a refresh rereads it.
/// One import runs at a time: the panel is not shown while one runs, and should one start while it is
/// open, Add says "Importing…" and the panel stays open, so the file is never dropped unsaid.
@MainActor enum PlaylistFilePanel {
    static func present(for model: AppModel) {
        guard !model.isImporting else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a playlist file"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let gate = ImportGate(model: model)
        panel.delegate = gate  // held weakly by the panel; the completion below keeps it
        panel.begin { response in
            withExtendedLifetime(gate) {}
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await model.addPlaylist(location: url.path) }
        }
    }
}

/// Refuses Add while an import runs, saying why; the panel stays open for a later Add.
@MainActor private final class ImportGate: NSObject, NSOpenSavePanelDelegate {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard model.isImporting else { return }
        throw NSError(domain: "Tuner", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Importing…",
            NSLocalizedRecoverySuggestionErrorKey: "Add the file once the import has finished.",
        ])
    }
}
