/// What the main window shows around the video, and the rules for changing it: whether the channel
/// list (or the search results over it) is laid over the video, whether the video has the whole
/// screen, and where the keyboard goes after each change. A value with no view in it: the window
/// sends it what happened and does what it answers.
public struct WindowState: Equatable, Sendable {
    /// The channel list shows over the video. Put away, it leaves the video alone.
    public private(set) var showsChannelList = true
    /// The video alone, filling the screen.
    public private(set) var videoFullScreen = false

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
            showsChannelList = false
        case .stopped, .sectionChosen, .searchTyped, .searchFieldFocused:
            showsChannelList = true
        case .searchFieldRequested:
            // The field is in the sidebar, which full screen covers.
            showsChannelList = true
            videoFullScreen = false
            outcome.showSearchField = true
        case .toggleChannelList:
            showsChannelList.toggle()
        case .videoClicked:
            if playing { showsChannelList = false }
        case .toggleVideoFullScreen:
            videoFullScreen.toggle()
            if videoFullScreen, playing { showsChannelList = false }
        case .windowLeftFullScreen:
            videoFullScreen = false
        case .escape(let searching):
            // One thing at a time, outermost last: the search, then the channel list, then full
            // screen. In full screen the search field cannot be reached, so the list goes first.
            if showsChannelList, playing, !searching || videoFullScreen {
                showsChannelList = false
            } else if videoFullScreen {
                videoFullScreen = false
            } else if searching {
                outcome.leaveSearch = true
            }
        }
        if outcome.showSearchField || outcome.leaveSearch { return outcome }  // they move the keyboard themselves
        if videoFullScreen != before.videoFullScreen {
            outcome.focus = showsChannelList ? .channelList : .player
        } else if showsChannelList != before.showsChannelList {
            outcome.focus = showsChannelList ? .channelListUnlessSearchField : .player
        }
        return outcome
    }
}
