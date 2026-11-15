import AppKit
import SwiftUI

/// The main window's AppKit side: reports whether the window is on screen (not minimised, hidden,
/// covered or on another Space) and when it leaves full screen by any route, and takes the window in
/// and out of full screen for the video.
struct WindowBridge: NSViewRepresentable {
    let videoFullScreen: Bool
    let visibilityChanged: (Bool) -> Void
    let leftFullScreen: () -> Void

    func makeNSView(context: Context) -> WindowBridgeView { WindowBridgeView() }

    func updateNSView(_ view: WindowBridgeView, context: Context) {
        view.visibilityChanged = visibilityChanged
        view.leftFullScreen = leftFullScreen
        view.setVideoFullScreen(videoFullScreen)
    }
}

final class WindowBridgeView: NSView {
    var visibilityChanged: ((Bool) -> Void)?
    var leftFullScreen: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    /// What was asked for last: the video alone, full screen.
    private var videoFullScreen = false
    /// The window was not full screen before the video took it there, so leaving the video's full
    /// screen leaves the window's too.
    private var restoreWindowed = false
    /// The window is going into or out of full screen, or has just been asked to. AppKit cannot turn
    /// round in the middle, so a request made meanwhile waits for the end of it (see `matchRequest`).
    private var inTransition = false
    private var transitionBegan = false
    /// When the transition began. AppKit tells a failed transition only to the window's delegate, which
    /// is SwiftUI's, so one that never ends stops holding requests back after `transitionLimit`.
    private var transitionStartedAt: TimeInterval = 0
    private static let transitionLimit: TimeInterval = 5

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        inTransition = false
        guard let window else {
            visibilityChanged?(false)
            return
        }
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ action: @escaping @MainActor (WindowBridgeView) -> Void) {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self { action(self) }
                }
            })
        }
        observe(NSWindow.didChangeOcclusionStateNotification) { $0.reportVisibility() }
        observe(NSWindow.willEnterFullScreenNotification) { $0.transitionWillBegin() }
        observe(NSWindow.willExitFullScreenNotification) { $0.transitionWillBegin() }
        observe(NSWindow.didEnterFullScreenNotification) { view in
            // Asked to leave while going in: leave now. On the next turn: AppKit is still finishing
            // the transition while it tells of its end, and ignores a toggle made then.
            view.inTransition = false
            DispatchQueue.main.async { [weak view] in view?.matchRequest() }
        }
        observe(NSWindow.didExitFullScreenNotification) { view in
            // By any route. A request to go back in made while it was leaving is dropped.
            view.inTransition = false
            view.restoreWindowed = false
            view.leftFullScreen?()
        }
        reportVisibility()
    }

    func setVideoFullScreen(_ on: Bool) {
        guard on != videoFullScreen else { return }
        videoFullScreen = on
        // Not during SwiftUI's update pass, which this is called from.
        DispatchQueue.main.async { [weak self] in self?.matchRequest() }
    }

    /// Takes the window into or out of full screen as last asked, unless a transition is under way: its
    /// end calls this again. However quickly requests come, the window ends full screen with the video
    /// alone, or as it was with the panes.
    private func matchRequest() {
        let now = ProcessInfo.processInfo.systemUptime
        if inTransition, now - transitionStartedAt < Self.transitionLimit { return }
        guard let window else { return }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        if videoFullScreen {
            guard !isFullScreen else { return }  // there already, by this or by the owner beforehand
            restoreWindowed = true
        } else {
            guard restoreWindowed, isFullScreen else { return }
        }
        inTransition = true
        transitionBegan = false
        transitionStartedAt = now
        window.toggleFullScreen(nil)
        // AppKit says it is starting before it returns. Had it not started (the window cannot go full
        // screen just now), nothing is left waiting.
        if !transitionBegan {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.transitionBegan else { return }
                self.inTransition = false
            }
        }
    }

    private func transitionWillBegin() {
        if !inTransition { transitionStartedAt = ProcessInfo.processInfo.systemUptime }
        inTransition = true
        transitionBegan = true
    }

    private func reportVisibility() {
        visibilityChanged?(window?.occlusionState.contains(.visible) ?? false)
    }

    /// It sits behind the whole window and must never take a click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
