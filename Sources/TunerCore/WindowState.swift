/// What the main window shows around the video, and the rules for changing it: whether the channel
/// list (or the search results over it) is laid over the video, whether the video has the whole
/// screen or is a small picture floating over other apps, and where the keyboard goes after each
/// change. A value with no view in it: the window
/// sends it what happened and does what it answers.
public struct WindowState: Equatable, Sendable {
    /// The channel list shows over the video. Put away, it leaves the video alone.
    public private(set) var showsChannelList = true
    /// The video alone, filling the screen.
    public private(set) var videoFullScreen = false
    /// Picture in picture: the window is a small video floating over other apps. Only while
    /// something plays, never with the channel list, and never full screen.
    public private(set) var pictureInPicture = false
    /// The guide fills the pane, with the video docked small in its corner. Never with the channel
    /// list, full screen or the small picture: whatever shows one of those leaves the guide.
    public private(set) var showsGuide = false

    public init() {}

    public enum Event: Equatable, Sendable {
        /// A channel was asked to play, by any route.
        case played
        case stopped
        /// A sidebar section was clicked, the one showing included.
        case sectionChosen
        /// The search text became something.
        case searchTyped
        /// The search field took the keyboard (a click on it).
        case searchFieldFocused
        /// ⌘F, or a letter typed in a list.
        case searchFieldRequested
        /// ⌘L.
        case toggleChannelList
        case videoClicked
        /// ⌘⏎, F, or a double-click on the video.
        case toggleVideoFullScreen
        /// ⌘⇧P, or a double-click on the small picture.
        case togglePictureInPicture
        /// The sidebar's Guide row.
        case guideChosen
        /// ⌘G.
        case toggleGuide
        /// A programme was played from the guide: back to the video.
        case leaveGuide
        /// The window left full screen by a route of its own (the green button, Mission Control).
        case windowLeftFullScreen
        /// `searching`: the search has text, or its field has the keyboard.
        case escape(searching: Bool)
    }

    /// Where the keyboard should go.
    public enum Focus: Equatable, Sendable {
        case player
        case channelList
        /// The channel list, unless the search field has the keyboard or is about to get it.
        case channelListUnlessSearchField
        case guide
    }

    /// What the window must do after an event, beyond showing the state as it now is.
    public struct Outcome: Equatable, Sendable {
        /// Move the keyboard, on the next turn, once the list is covered or uncovered.
        public var focus: Focus?
        /// Show the search field (the sidebar too, if hidden) and give it the keyboard.
        public var showSearchField = false
        /// Clear the search and go back to the channel list.
        public var leaveSearch = false

        public init(focus: Focus? = nil, showSearchField: Bool = false, leaveSearch: Bool = false) {
            self.focus = focus
            self.showSearchField = showSearchField
            self.leaveSearch = leaveSearch
        }
    }

    /// `playing`: a channel is playing, or was asked to. With nothing playing the list is never put
    /// away for the video's sake, or the pane would be left blank.
    public mutating func handle(_ event: Event, playing: Bool) -> Outcome {
        let before = self
        var outcome = Outcome()
        switch event {
        case .played:
            showsChannelList = false  // from the guide's own keys (⌘1, say) it plays docked
        case .stopped:
            if !showsGuide { showsChannelList = true }
        case .sectionChosen, .searchTyped, .searchFieldFocused:
            showsChannelList = true
            showsGuide = false
        case .searchFieldRequested:
            // The field is in the sidebar, which full screen covers.
            showsChannelList = true
            showsGuide = false
            videoFullScreen = false
            outcome.showSearchField = true
        case .toggleChannelList:
            if showsGuide {
                showsGuide = false
                showsChannelList = true
            } else {
                showsChannelList.toggle()
            }
        case .videoClicked:
            // On the docked video it goes back to the video.
            if playing {
                showsChannelList = false
                showsGuide = false
            }
        case .guideChosen:
            showGuide()
        case .toggleGuide:
            if showsGuide { leaveGuide(playing: playing) } else { showGuide() }
        case .leaveGuide:
            leaveGuide(playing: playing)
        case .toggleVideoFullScreen:
            // From the guide, the video goes full screen; with nothing playing there is none to.
            if showsGuide {
                guard playing else { break }
                showsGuide = false
            }
            videoFullScreen.toggle()
            if videoFullScreen, playing { showsChannelList = false }
            pictureInPicture = false
        case .togglePictureInPicture:
            if pictureInPicture {
                pictureInPicture = false
            } else if playing {
                pictureInPicture = true
                videoFullScreen = false
                showsChannelList = false
                showsGuide = false
            }
        case .windowLeftFullScreen:
            videoFullScreen = false
        case .escape(let searching):
            // One thing at a time, outermost last: the search, then the channel list, then full
            // screen. In full screen the search field cannot be reached, so the list goes first.
            if pictureInPicture {
                pictureInPicture = false
            } else if showsGuide {
                leaveGuide(playing: playing)
            } else if showsChannelList, playing, !searching || videoFullScreen {
                showsChannelList = false
            } else if videoFullScreen {
                videoFullScreen = false
            } else if searching {
                outcome.leaveSearch = true
            }
        }
        // The small picture has no room for the list: whatever shows the list brings the window back.
        if showsChannelList { pictureInPicture = false }
        if outcome.showSearchField || outcome.leaveSearch { return outcome }  // they move the keyboard themselves
        if showsGuide {
            if !before.showsGuide { outcome.focus = .guide }
        } else if before.showsGuide {
            outcome.focus = showsChannelList ? .channelListUnlessSearchField : .player
        } else if videoFullScreen != before.videoFullScreen || pictureInPicture != before.pictureInPicture {
            outcome.focus = showsChannelList ? .channelList : .player
        } else if showsChannelList != before.showsChannelList {
            outcome.focus = showsChannelList ? .channelListUnlessSearchField : .player
        }
        return outcome
    }

    private mutating func showGuide() {
        showsGuide = true
        showsChannelList = false
        videoFullScreen = false
        pictureInPicture = false
    }

    /// Back to the video, or to the channel list when nothing plays.
    private mutating func leaveGuide(playing: Bool) {
        showsGuide = false
        if !playing { showsChannelList = true }
    }
}
