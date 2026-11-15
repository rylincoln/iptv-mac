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
    /// is SwiftUI's, so this view would wait for its end for ever. After `transitionLimit` it stops
    /// waiting, but nothing wakes it then: a request held meanwhile is acted on only when the next
    /// request or full-screen notification comes.
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
        observe(NSWindow.willEnterFullScreenNotification) { view in
            // Going in with the video not asking (the owner's own full screen): it is theirs to keep,
            // whatever a transition that failed earlier left behind.
            if !view.videoFullScreen { view.restoreWindowed = false }
            view.transitionWillBegin()
        }
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

    /// Takes the window into or out of full screen as last asked, unless a transition is under way. The
    /// end of going in calls this again, so a request to leave made meanwhile is acted on; the end of
    /// leaving drops a request to go back in and ends the video's full screen with the window's. So
    /// however quickly requests come, a window whose transitions end finishes full screen with the
    /// video alone, or as it was with the panes. A transition that never ends holds the last request
    /// back (see `transitionStartedAt`).
    private func matchRequest() {
        let now = ProcessInfo.processInfo.systemUptime
        if inTransition, now - transitionStartedAt < Self.transitionLimit { return }
        guard let window else { return }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        if videoFullScreen {
            guard !isFullScreen else { return }  // there already, by this or by the owner beforehand
            restoreWindowed = true
        } else {
            guard isFullScreen else {
                // Windowed, and no transition under way: the video never took the window full screen,
                // so a full screen the owner chooses later is theirs to keep.
                restoreWindowed = false
                return
            }
            guard restoreWindowed else { return }
        }
        inTransition = true
        transitionBegan = false
        transitionStartedAt = now
        window.toggleFullScreen(nil)
        // AppKit says it is starting before it returns. Had it not started (the window cannot go full
        // screen just now), nothing is left waiting, and a window that stayed windowed has nothing to
        // be restored to.
        if !transitionBegan {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.transitionBegan else { return }
                self.inTransition = false
                if self.window?.styleMask.contains(.fullScreen) == false { self.restoreWindowed = false }
            }
        }
    }

    private func transitionWillBegin() {
        // Timed from here every time: a transition that never ended may have left `inTransition` set,
        // and this one must not inherit its start.
        transitionStartedAt = ProcessInfo.processInfo.systemUptime
        inTransition = true
        transitionBegan = true
    }

    private func reportVisibility() {
        visibilityChanged?(window?.occlusionState.contains(.visible) ?? false)
    }

    /// It sits behind the whole window and must never take a click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
