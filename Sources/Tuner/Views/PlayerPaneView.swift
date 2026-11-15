import AppKit
import SwiftUI
import TunerCore

/// The window's main pane: the video, filling it, and over the video whatever is asked for. The
/// channel list (or the search results) is a drawer down the leading edge; what is on is a card at
/// the bottom. Everything over the video is flat and slightly see-through: no blur, so nothing is
/// sampled from the video as it plays.
struct PlayerPaneView: View {
    let model: AppModel
    var focus: FocusState<PaneFocus?>.Binding
    /// The height of the toolbar lying over the pane's top edge; none in full screen.
    let topInset: CGFloat
    @State private var idle = IdleWatch()
    /// Where the pointer and the window were when a drag of the small picture began.
    @State private var pictureDrag: (pointer: NSPoint, window: NSPoint)?
    @AppStorage(PictureSettings.snapsToCornersKey) private var pictureSnapsToCorners = true

    /// The drawer's width, and how far in the card sits while the drawer shows.
    private static let drawerWidth: CGFloat = 340

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            video
            InfoCard(model: model, idle: idle)
                .padding(.leading, model.showsChannelList ? Self.drawerWidth : 0)
            drawer
        }
        .overlay(alignment: .bottomTrailing) { PictureButton(model: model, idle: idle) }
        .overlay(alignment: .topTrailing) {
            if model.showsStats { StatsOverlay(readout: model.statsReadout).padding(.top, topInset) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            idle.hidesPointer = model.videoFullScreen
            idle.start(over: model.videoView)
        }
        .onChange(of: model.videoFullScreen) { _, on in
            idle.hidesPointer = on
            idle.pointerMoved()
        }
        .onDisappear { idle.stop() }
    }

    /// One `VideoView` for the window's whole life, so the player's view is never moved to another
    /// container. It keeps its shape, centred on black.
    private var video: some View {
        ZStack {
            Color.black
            VideoView(videoView: model.videoView)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
            clickLayer
            PlaybackStatusOverlay(model: model)  // above the click layer: Try Again is a button
                .padding(.top, topInset)
        }
        .focusable()
        .focusEffectDisabled()
        .focused(focus, equals: .player)
        .onKeyPress(characters: CharacterSet(charactersIn: "fF"), phases: .down) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
            model.send(.toggleVideoFullScreen)
            return .handled
        }
    }

    /// Takes clicks before the AppKit video view does. A click gives the video the keyboard, so F
    /// works, and puts the channel list away if something is playing; a double-click toggles full
    /// screen. Pointer movement over it shows the card.
    private var clickLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                // The small picture goes back to the window; otherwise in and out of full screen.
                model.send(model.pictureInPicture ? .togglePictureInPicture : .toggleVideoFullScreen)
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    model.send(.videoClicked)
                    focus.wrappedValue = .player
                }
            )
            .onContinuousHover { phase in
                if case .active = phase { idle.pointerMoved() }
            }
            // The small picture is moved by dragging it anywhere. The layer takes the mouse before
            // the window can, so the window is moved here: by as far as the pointer has gone on the
            // screen since the drag began, kept wholly on the screen the pointer is on; let go, it
            // settles into that screen's nearest corner, unless that is turned off in the View menu.
            .simultaneousGesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { _ in
                        guard let window = model.videoView.window else { return }
                        let pointer = NSEvent.mouseLocation
                        let start = pictureDrag ?? (pointer, window.frame.origin)
                        if pictureDrag == nil { pictureDrag = start }
                        let moved = NSRect(
                            origin: NSPoint(
                                x: start.window.x + pointer.x - start.pointer.x,
                                y: start.window.y + pointer.y - start.pointer.y),
                            size: window.frame.size)
                        guard let screen = Self.screen(under: pointer, or: window) else { return }
                        window.setFrameOrigin(PicturePlacement.kept(moved, on: screen).origin)
                    }
                    .onEnded { _ in
                        pictureDrag = nil
                        guard pictureSnapsToCorners, model.pictureInPicture, let window = model.videoView.window,
                              let screen = Self.screen(under: NSEvent.mouseLocation, or: window)
                        else { return }
                        let corner = PicturePlacement.snapped(
                            window.frame, on: screen, margin: WindowBridgeView.pictureMargin)
                        if corner != window.frame { window.setFrame(corner, display: true, animate: true) }
                    },
                isEnabled: model.pictureInPicture)
    }

    /// The usable area of the screen the pointer is on, else of the window's own.
    private static func screen(under pointer: NSPoint, or window: NSWindow) -> NSRect? {
        (NSScreen.screens.first { $0.frame.contains(pointer) } ?? window.screen)?.visibleFrame
    }

    /// The channel list, with the search results over it while they show. Put away, it stays in the
    /// window, unseen: it keeps its rows, selection and scroll position, and takes no keyboard,
    /// clicks or VoiceOver (see `ChannelListView`).
    private var drawer: some View {
        let shown = model.showsChannelList
        return ChannelListView(model: model, focus: focus)
            .scrollContentBackground(.hidden)
            .safeAreaPadding(.top, topInset)
            .frame(width: Self.drawerWidth)
            .frame(maxHeight: .infinity)
            .background(Color.black.opacity(0.8))
            .environment(\.colorScheme, .dark)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
            .animation(.easeOut(duration: 0.15), value: shown)
    }
}

/// What the video is doing when it is not simply playing. It alone watches `status`, so a change
/// rebuilds this and nothing else. It lets clicks through except on the Try Again button.
private struct PlaybackStatusOverlay: View {
    let model: AppModel

    var body: some View {
        switch model.status {
        case .idle, .playing:
            EmptyView()
        case .starting:
            ProgressView()
                .controlSize(.small)
                .padding(10)
                .background(.black.opacity(0.6), in: Circle())
                .environment(\.colorScheme, .dark)
                .accessibilityLabel("Starting")
                .allowsHitTesting(false)
        case .reconnecting:
            VStack {
                HStack {
                    Spacer()
                    Label("Reconnecting…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.8), in: Capsule())
                        .accessibilityLabel("Reconnecting")
                }
                Spacer()
            }
            .padding(12)
            .allowsHitTesting(false)
        case .unavailable:
            VStack(spacing: 12) {
                Text("Channel unavailable")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Button("Try Again") { model.retry() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// Over the video's bottom edge: the playing channel and its programme now. While the channel list
/// shows it stays up and says more (the description, what is next), or shows a later programme
/// picked from the search results. With the list away it is brief, shows while the pointer moves
/// and goes three seconds after the last movement. It alone watches the idle state and the guide,
/// and takes no clicks.
private struct InfoCard: View {
    let model: AppModel
    let idle: IdleWatch

    var body: some View {
        let full = model.showsChannelList
        let visible = full || !idle.isIdle
        ZStack(alignment: .bottomLeading) {
            if visible {
                if full, let chosen = model.chosenProgramme {
                    // A later programme picked from the search results; playback is unchanged.
                    card(channel: chosen.channel, programme: chosen.programme, upNext: [], full: true)
                } else if let channel = model.playingChannel {
                    card(
                        channel: channel,
                        programme: channel.guideRef.flatMap { model.nowPlaying[$0] },
                        upNext: full ? model.upNext : [],
                        full: full)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: visible)
        .allowsHitTesting(false)
    }

    private func card(channel: ChannelRow, programme: ProgrammeRow?, upNext: [ProgrammeRow], full: Bool) -> some View {
        let now = model.nowPlayingAt
        return VStack(alignment: .leading, spacing: 4) {
            Text(channel.name)
                .font(programme == nil ? .title2.weight(.semibold) : .headline)
                .foregroundStyle(programme == nil ? .white : .white.opacity(0.7))
                .lineLimit(1)
            if let programme {
                Text(programme.title).font(.title2.weight(.semibold)).lineLimit(2)
                if let subTitle = programme.subTitle, !subTitle.isEmpty {
                    Text(subTitle).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text("\(StartTime.text(programme.start, days: StartTimeForm.Days(now: now))) – \(time(programme.stop))")
                        .foregroundStyle(.white.opacity(0.7))
                        .monospacedDigit()
                    if programme.start <= now && now < programme.stop { LiveBadge() }
                }
                if full, let desc = programme.desc, !desc.isEmpty {
                    Text(desc)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(4)
                        .padding(.top, 4)
                }
            } else if let group = channel.groupTitle {
                Text(group).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            if !upNext.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(upNext) { programme in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(time(programme.start)).foregroundStyle(.white.opacity(0.7)).monospacedDigit()
                            Text(programme.title).lineLimit(1)
                        }
                    }
                }
                .font(.callout)
                .padding(.top, 6)
            }
        }
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 460, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
        .padding(20)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }

    /// Local time, in the Mac's own format.
    private func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// Over the video's bottom corner while the pointer moves, as the card is: makes the window the
/// small floating picture, or brings it back. Only while something plays. It alone watches the idle
/// state.
private struct PictureButton: View {
    let model: AppModel
    let idle: IdleWatch

    var body: some View {
        let small = model.pictureInPicture
        let visible = !idle.isIdle && (small || model.playingChannel != nil)
        ZStack {
            if visible {
                Button {
                    model.send(.togglePictureInPicture)
                } label: {
                    Image(systemName: small ? "pip.exit" : "pip.enter")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(.black.opacity(0.8), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(small ? "Exit Picture in Picture" : "Picture in Picture")
                .accessibilityLabel(small ? "Exit Picture in Picture" : "Picture in Picture")
                // The pointer over the button is still the pointer moving over the video.
                .onContinuousHover { phase in
                    if case .active = phase { idle.pointerMoved() }
                }
                .padding(small ? 10 : 20)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: visible)
    }
}

struct LiveBadge: View {
    var body: some View {
        Text("LIVE")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.red, in: Capsule())
    }
}

/// Notices three seconds without pointer movement over the video. The card over the video hides
/// while `isIdle` is true, and in full screen (`hidesPointer`) so does the pointer, but only while it
/// is over this window and Tuner is the active app, never on another display or over another app.
/// Its one timer exists only between `start` and `stop`, and does not fire again once the pointer is
/// still until it next moves.
@MainActor @Observable private final class IdleWatch {
    static let delay: TimeInterval = 3

    private(set) var isIdle = false
    @ObservationIgnored var hidesPointer = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastMove: TimeInterval = 0
    @ObservationIgnored private weak var view: NSView?

    func start(over view: NSView) {
        stop()
        self.view = view
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
        view = nil
        if isIdle { isIdle = false }
    }

    /// Cheap: called for every pointer movement, it only notes the time unless the card was hidden.
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
        if hidesPointer, NSApp.isActive, let window = view?.window, window.frame.contains(NSEvent.mouseLocation) {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        timer.fireDate = .distantFuture  // nothing more to do until the pointer moves
    }
}
