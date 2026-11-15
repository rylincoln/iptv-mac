import Testing
@testable import TunerCore

private typealias Outcome = WindowState.Outcome

/// A state reached by the events given, with a channel playing throughout.
private func state(after events: WindowState.Event...) -> WindowState {
    var state = WindowState()
    for event in events { _ = state.handle(event, playing: true) }
    return state
}

@Suite struct WindowStateTests {
    @Test func itStartsWithTheListShownAndWindowed() {
        let state = WindowState()
        #expect(state.showsChannelList)
        #expect(!state.videoFullScreen)
    }

    @Test func playingPutsTheListAwayAndGivesTheVideoTheKeyboard() {
        var state = WindowState()
        #expect(state.handle(.played, playing: true) == Outcome(focus: .player))
        #expect(!state.showsChannelList)
        // Again, with the list already away: nothing to move.
        #expect(state.handle(.played, playing: true) == Outcome())
    }

    @Test(arguments: [WindowState.Event.stopped, .sectionChosen, .searchTyped, .searchFieldFocused])
    func theListComesBack(for event: WindowState.Event) {
        var state = state(after: .played)
        #expect(state.handle(event, playing: true) == Outcome(focus: .channelListUnlessSearchField))
        #expect(state.showsChannelList)
        // Already shown: the keyboard stays where it is.
        #expect(state.handle(event, playing: true) == Outcome())
    }

    @Test func theToggleShowsAndHidesTheListEvenWithNothingPlaying() {
        var state = WindowState()
        #expect(state.handle(.toggleChannelList, playing: false) == Outcome(focus: .player))
        #expect(!state.showsChannelList)
        #expect(state.handle(.toggleChannelList, playing: false) == Outcome(focus: .channelListUnlessSearchField))
        #expect(state.showsChannelList)
    }

    @Test func aClickOnTheVideoPutsTheListAwayOnlyWhileSomethingPlays() {
        var state = WindowState()
        #expect(state.handle(.videoClicked, playing: false) == Outcome())
        #expect(state.showsChannelList)
        #expect(state.handle(.videoClicked, playing: true) == Outcome(focus: .player))
        #expect(!state.showsChannelList)
    }

    @Test func fullScreenLeavesAPlayingVideoAlone() {
        var state = WindowState()
        #expect(state.handle(.toggleVideoFullScreen, playing: true) == Outcome(focus: .player))
        #expect(state.videoFullScreen)
        #expect(!state.showsChannelList)
        #expect(state.handle(.toggleVideoFullScreen, playing: true) == Outcome(focus: .player))
        #expect(!state.videoFullScreen)
        #expect(!state.showsChannelList)
    }

    @Test func fullScreenWithNothingPlayingKeepsTheListAndItsKeyboard() {
        var state = WindowState()
        #expect(state.handle(.toggleVideoFullScreen, playing: false) == Outcome(focus: .channelList))
        #expect(state.videoFullScreen)
        #expect(state.showsChannelList)
    }

    @Test func theListCanBeBrowsedInFullScreen() {
        var state = state(after: .toggleVideoFullScreen)
        #expect(state.handle(.toggleChannelList, playing: true) == Outcome(focus: .channelListUnlessSearchField))
        #expect(state.videoFullScreen)
        #expect(state.showsChannelList)
    }

    @Test func theWindowLeavingFullScreenByItselfEndsTheVideosFullScreen() {
        var state = state(after: .toggleVideoFullScreen)
        #expect(state.handle(.windowLeftFullScreen, playing: true) == Outcome(focus: .player))
        #expect(!state.videoFullScreen)
        // Windowed already: nothing changes.
        #expect(state.handle(.windowLeftFullScreen, playing: true) == Outcome())
    }

    @Test func askingForTheSearchFieldLeavesFullScreenAndShowsTheList() {
        var state = state(after: .toggleVideoFullScreen)
        #expect(state.handle(.searchFieldRequested, playing: true) == Outcome(showSearchField: true))
        #expect(!state.videoFullScreen)
        #expect(state.showsChannelList)
        // Windowed with the list shown, it still asks for the field.
        #expect(state.handle(.searchFieldRequested, playing: true) == Outcome(showSearchField: true))
    }

    // MARK: Escape

    @Test func escapeLeavesTheSearchFirstWhenWindowed() {
        var state = WindowState()
        #expect(state.handle(.escape(searching: true), playing: true) == Outcome(leaveSearch: true))
        #expect(state.showsChannelList)
    }

    @Test func escapeThenPutsTheListAwayWhileSomethingPlays() {
        var state = WindowState()
        #expect(state.handle(.escape(searching: false), playing: true) == Outcome(focus: .player))
        #expect(!state.showsChannelList)
        // Nothing left to leave.
        #expect(state.handle(.escape(searching: false), playing: true) == Outcome())
    }

    @Test func escapeNeverBlanksThePaneWhenNothingPlays() {
        var state = WindowState()
        #expect(state.handle(.escape(searching: false), playing: false) == Outcome())
        #expect(state.showsChannelList)
    }

    @Test func escapeInFullScreenPutsTheListAwayThenLeavesFullScreen() {
        var state = state(after: .toggleVideoFullScreen, .toggleChannelList)
        #expect(state.handle(.escape(searching: true), playing: true) == Outcome(focus: .player))
        #expect(state.videoFullScreen)
        #expect(!state.showsChannelList)
        #expect(state.handle(.escape(searching: false), playing: true) == Outcome(focus: .player))
        #expect(!state.videoFullScreen)
    }

    @Test func escapeInFullScreenWithNothingPlayingLeavesFullScreenAndKeepsTheList() {
        var state = WindowState()
        _ = state.handle(.toggleVideoFullScreen, playing: false)
        #expect(state.handle(.escape(searching: false), playing: false) == Outcome(focus: .channelList))
        #expect(!state.videoFullScreen)
        #expect(state.showsChannelList)
    }

    @Test func escapeWithTheListAwayAndTextLeftInTheFieldLeavesTheSearch() {
        // A result was played from the field: the list went away with the text still there.
        var state = state(after: .played)
        #expect(state.handle(.escape(searching: true), playing: true) == Outcome(leaveSearch: true))
    }

    // MARK: Picture in picture

    @Test func pictureInPictureLeavesThePlayingVideoAloneAndSmall() {
        var state = WindowState()
        #expect(state.handle(.togglePictureInPicture, playing: true) == Outcome(focus: .player))
        #expect(state.pictureInPicture)
        #expect(!state.showsChannelList)
        #expect(state.handle(.togglePictureInPicture, playing: true) == Outcome(focus: .player))
        #expect(!state.pictureInPicture)
    }

    @Test func pictureInPictureNeedsSomethingPlaying() {
        var state = WindowState()
        #expect(state.handle(.togglePictureInPicture, playing: false) == Outcome())
        #expect(!state.pictureInPicture)
    }

    @Test func pictureInPictureAndFullScreenReplaceEachOther() {
        var state = state(after: .toggleVideoFullScreen)
        _ = state.handle(.togglePictureInPicture, playing: true)
        #expect(state.pictureInPicture)
        #expect(!state.videoFullScreen)
        _ = state.handle(.toggleVideoFullScreen, playing: true)
        #expect(!state.pictureInPicture)
        #expect(state.videoFullScreen)
    }

    @Test func playingAnotherChannelKeepsThePictureSmall() {
        var state = state(after: .togglePictureInPicture)
        #expect(state.handle(.played, playing: true) == Outcome())
        #expect(state.pictureInPicture)
    }

    @Test(arguments: [WindowState.Event.stopped, .toggleChannelList, .searchFieldRequested])
    func whateverShowsTheListBringsTheWindowBack(_ event: WindowState.Event) {
        var state = state(after: .togglePictureInPicture)
        _ = state.handle(event, playing: true)
        #expect(!state.pictureInPicture)
        #expect(state.showsChannelList)
    }

    @Test func escapeLeavesPictureInPictureFirst() {
        var state = state(after: .togglePictureInPicture)
        #expect(state.handle(.escape(searching: true), playing: true) == Outcome(focus: .player))
        #expect(!state.pictureInPicture)
        #expect(!state.showsChannelList)
    }
}
