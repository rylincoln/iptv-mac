import AppKit
import SwiftUI
import TunerCore

/// The video, and under it what is on. In full screen only the video shows, filling the screen.
struct PlayerPaneView: View {
    let model: AppModel
    @Binding var isFullScreen: Bool
    var focus: FocusState<PaneFocus?>.Binding
    @State private var idle = IdleWatch()

    var body: some View {
        VStack(spacing: 0) {
            video.layoutPriority(1)  // full width first; the details take what is left
            if !isFullScreen {
                ProgrammeDetails(
                    channel: model.playingChannel,
                    programme: model.playingChannel?.guideRef.flatMap { model.nowPlaying[$0] },
                    upNext: model.upNext,
                    now: model.nowPlayingAt)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isFullScreen ? .center : .top)
        .background(isFullScreen ? Color.black : Color.clear)
        .ignoresSafeArea(edges: isFullScreen ? .all : [])
        .focusable()
        .focusEffectDisabled()
        .focused(focus, equals: .player)
        .onKeyPress(characters: CharacterSet(charactersIn: "fF"), phases: .down) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
            isFullScreen.toggle()
            return .handled
        }
        .onChange(of: isFullScreen) { _, on in
            if on { idle.start(in: model.videoView.window) } else { idle.stop() }
        }
        .onDisappear { idle.stop() }
    }

    /// One `VideoView` in both layouts, so the player's view is never moved to another container.
    private var video: some View {
        VideoView(videoView: model.videoView)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: isFullScreen ? .infinity : nil)
            .background(Color.black)
            .overlay {
                if isFullScreen {
                    clickLayer.onContinuousHover { phase in
                        if case .active = phase { idle.pointerMoved() }
                    }
                } else {
                    clickLayer
                }
            }
    }

    /// Takes clicks before the AppKit video view does: a click focuses the pane, so F works, and a
    /// double-click toggles full screen.
    private var clickLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { isFullScreen.toggle() }
            .simultaneousGesture(TapGesture().onEnded { focus.wrappedValue = .player })
    }
}

/// Under the video: the playing channel's programme now, then what follows. With no guide data, the
/// channel's name and group.
private struct ProgrammeDetails: View {
    let channel: ChannelRow?
    let programme: ProgrammeRow?
    let upNext: [ProgrammeRow]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let channel {
                if let programme {
                    header(channel: channel, programme: programme)
                    if let desc = programme.desc, !desc.isEmpty {
                        // Plain text when it fits; scrolls when it is long.
                        ViewThatFits(in: .vertical) {
                            description(desc)
                            ScrollView { description(desc) }
                        }
                        .layoutPriority(1)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(channel.name).font(.title3.weight(.semibold)).lineLimit(2)
                        if let group = channel.groupTitle {
                            Text(group).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !upNext.isEmpty { next }
            } else {
                Text("Nothing playing")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func header(channel: ChannelRow, programme: ProgrammeRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(channel.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            Text(programme.title).font(.title3.weight(.semibold)).lineLimit(2)
            if let subTitle = programme.subTitle, !subTitle.isEmpty {
                Text(subTitle).lineLimit(2)
            }
            HStack(spacing: 6) {
                Text("\(time(programme.start)) – \(time(programme.stop))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if programme.start <= now && now < programme.stop {
                    LiveBadge()
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func description(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var next: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Next").font(.headline)
            ForEach(upNext) { programme in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(time(programme.start)).foregroundStyle(.secondary).monospacedDigit()
                    Text(programme.title).lineLimit(1)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Local time, in the Mac's own format.
    private func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

private struct LiveBadge: View {
    var body: some View {
        Text("LIVE")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.red, in: Capsule())
    }
}

/// Notices three seconds without pointer movement over the full-screen video, then hides the pointer.
/// Overlay controls over the video hide while `isIdle` is true. Its one timer exists only between
/// `start` and `stop`. The pointer is hidden only while it is over this window and Tuner is the
/// active app, never on another display or over another app.
@MainActor @Observable private final class IdleWatch {
    static let delay: TimeInterval = 3

    private(set) var isIdle = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastMove: TimeInterval = 0
    @ObservationIgnored private weak var window: NSWindow?

    func start(in window: NSWindow?) {
        stop()
        self.window = window
        lastMove = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: Self.delay, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        window = nil
        if isIdle { isIdle = false }
    }

    /// Cheap: called for every pointer movement, it only notes the time unless the pointer was hidden.
    func pointerMoved() {
        lastMove = ProcessInfo.processInfo.systemUptime
        guard isIdle, let timer else { return }
        isIdle = false
        timer.fireDate = Date(timeIntervalSinceNow: Self.delay)
    }

    private func check() {
        guard let timer else { return }
        let still = ProcessInfo.processInfo.systemUptime - lastMove
        if still < Self.delay - timer.tolerance {
            timer.fireDate = Date(timeIntervalSinceNow: Self.delay - still)
            return
        }
        isIdle = true
        if NSApp.isActive, let window, window.frame.contains(NSEvent.mouseLocation) {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        timer.fireDate = .distantFuture  // nothing more to do until the pointer moves
    }
}
