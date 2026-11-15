import SwiftUI
import TunerCore

/// One text field for a playlist or guide URL. One import runs at a time: while one does, Add says
/// "Importing…" and waits, and the text is kept for an Add once it has finished.
struct SourceURLSheet: View {
    let kind: SourceKind
    /// Read for `isImporting` alone.
    let model: AppModel
    let add: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == .playlist ? "Add Playlist URL" : "Add Guide URL").font(.headline)
            TextField("http://", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 440)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.isImporting ? "Importing…" : "Add", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(location == nil || model.isImporting)
            }
        }
        .padding(20)
    }

    /// The trimmed text when it is an http(s) URL with a host.
    private var location: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://"),
              let host = URL(string: trimmed)?.host, !host.isEmpty
        else { return nil }
        return trimmed
    }

    private func submit() {
        guard let location, !model.isImporting else { return }
        add(location)
        dismiss()
    }
}
