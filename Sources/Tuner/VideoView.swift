import AppKit
import SwiftUI

/// Places the player's one video view in the SwiftUI hierarchy. `VLCPlayer` owns the view; this
/// only hosts it in a black container that resizes it.
struct VideoView: NSViewRepresentable {
    let videoView: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if videoView.superview == nil { attach(to: container) }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        for subview in container.subviews { subview.removeFromSuperview() }
    }

    private func attach(to container: NSView) {
        videoView.frame = container.bounds
        videoView.autoresizingMask = [.width, .height]
        container.addSubview(videoView)
    }
}
