import AppKit
import SwiftUI
import TunerCore

@main
struct TunerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.open()

    var body: some Scene {
        // One window: there is one player and one video view.
        Window("Tuner", id: "main") {
            if let model {
                MainWindow(model: model)
            } else {
                ContentUnavailableView("Tuner could not open its library", systemImage: "exclamationmark.triangle")
                    .frame(minWidth: 480, minHeight: 300)
            }
        }
        .defaultSize(width: 1280, height: 760)
        .commands {
            SourceCommands(model: model)
            ChannelCommands(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
