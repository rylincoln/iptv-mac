import SwiftUI
import TunerCore

// MARK: - Sources

/// One import runs at a time, and a request made meanwhile is not queued: while one runs, these items
/// are disabled and the last of them reads "Importing…" to say why.
struct SourceCommands: Commands {
    let model: AppModel?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Group {
                Button("Add Playlist File…") {
                    if let model { PlaylistFilePanel.present(for: model) }
                }
                Button("Add Playlist URL…") { model?.sourcePrompt = .playlist }
                Button("Add Guide URL…") { model?.sourcePrompt = .guide }
                Divider()
                Button(model?.isImporting == true ? "Importing…" : "Refresh Sources") {
                    if let model { Task { await model.refreshAll() } }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            .disabled(model?.isImporting ?? true)
        }
    }
}

// MARK: - Channel shortcuts

/// Menu items, so the shortcuts work whichever pane has the keyboard, full screen included.
struct ChannelCommands: Commands {
    let model: AppModel?

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find…") { model?.requestSearchField() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model == nil)
        }
        CommandMenu("Channel") {
            Group {
                Button("Toggle Favourite") { model?.toggleFavouriteOnSelection() }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Previous Channel") { model?.playPrevious() }
                    .keyboardShortcut("[", modifiers: .command)
                // Closes the stream, which frees the provider connection, and lets the display sleep.
                Button("Stop") { model?.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled((model?.status ?? .idle) == .idle)
                Divider()
                ForEach(1...9, id: \.self) { number in
                    Button("Play Recent \(number)") { model?.playRecent(number - 1) }
                        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                }
                Divider()
                Button(model?.showsStats == true ? "Hide Playback Stats" : "Show Playback Stats") {
                    model?.toggleStats()
                }
                .keyboardShortcut("i", modifiers: .command)
            }
            .disabled(model == nil)
        }
    }
}
