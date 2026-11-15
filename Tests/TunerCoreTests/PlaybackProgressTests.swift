import Testing
@testable import TunerCore

/// A play call begun at time 0, with counters the test moves.
private struct Rig {
    var progress = PlaybackProgress(startedAt: 0)
    var counters = PlayerStats.zero
    var enginePlaying = true
    var countersRead = 0

    mutating func state(at time: Double) -> PlayerState {
        var read = 0
        let counters = self.counters, playing = enginePlaying
        let state = progress.state(at: time, counters: { read += 1; return counters }, enginePlaying: { playing })
        countersRead += read
        return state
    }

    mutating func advance() {
        counters.positionMs += 1000
        counters.displayedPictures += 25
    }
}

@Suite struct PlaybackProgressTests {
    @Test func beforeAnyEventItIsOpening() {
        var rig = Rig()
        #expect(rig.state(at: 1) == .opening)
        #expect(!rig.progress.hasOpened)
        #expect(rig.countersRead == 0)  // the engine has no input to count yet
    }

    @Test func nothingButAnOpeningIsTakenFirst() {
        // A late Ended or Error of the stream being left must not fail this one's start.
        var rig = Rig()
        for event in [PlaybackProgress.Event.error, .ended, .buffering, .running] {
            rig.progress.take(event)
            #expect(rig.state(at: 1) == .opening)
            #expect(!rig.progress.hasOpened)
        }
        rig.progress.take(.opening)
        #expect(rig.progress.hasOpened)
        rig.progress.take(.error)
        #expect(rig.state(at: 2) == .error)
    }

    @Test(arguments: [PlaybackProgress.Event.ended, .error])
    func endedAndErrorAreFinal(_ event: PlaybackProgress.Event) {
        var rig = Rig()
        rig.progress.take(.opening)
        rig.progress.take(event)
        rig.progress.take(.running)
        rig.progress.take(.opening)
        rig.advance()
        #expect(rig.state(at: 5) == (event == .ended ? .ended : .error))
    }

    @Test func openedButNeverAdvancedIsStillOpening() {
        var rig = Rig()
        rig.progress.take(.opening)
        rig.progress.take(.running)
        #expect(rig.state(at: 1) == .opening)
    }

    @Test func countersAdvancingMeansPlayingWhateverTheEngineSays() {
        var rig = Rig()
        rig.progress.take(.opening)
        rig.progress.take(.buffering)  // where a healthy live stream sticks
        rig.advance()
        #expect(rig.state(at: 1) == .playing)
        rig.advance()
        #expect(rig.state(at: 2) == .playing)
    }

    @Test func bufferingWithNothingAdvancedSinceTheLastReadingIsBuffering() {
        var rig = Rig()
        rig.progress.take(.opening)
        rig.progress.take(.buffering)
        rig.advance()
        #expect(rig.state(at: 1) == .playing)
        #expect(rig.state(at: 2) == .buffering)
    }

    @Test func aPauseInTheCountersWhileRunningStillReadsAsPlaying() {
        var rig = Rig()
        rig.progress.take(.opening)
        rig.progress.take(.running)
        rig.advance()
        #expect(rig.state(at: 1) == .playing)
        #expect(rig.state(at: 2) == .playing)  // it has advanced before, and the engine does not say buffering
    }

    @Test func countersThatMoveWhileTheEngineIsNotPlayingDoNotCount() {
        var rig = Rig()
        rig.enginePlaying = false
        rig.progress.take(.opening)
        rig.progress.take(.buffering)
        rig.advance()
        #expect(rig.state(at: 1) == .buffering)
    }

    @Test func readingsCloserThanTheIntervalReuseTheVerdict() {
        var rig = Rig()
        rig.progress.take(.opening)
        rig.progress.take(.buffering)
        rig.advance()
        #expect(rig.state(at: 1) == .playing)
        #expect(rig.countersRead == 1)
        // Nothing has moved, but it is too soon to say so.
        #expect(rig.state(at: 1.2) == .playing)
        #expect(rig.state(at: 1.49) == .playing)
        #expect(rig.countersRead == 1)
        #expect(rig.state(at: 1.5) == .buffering)
        #expect(rig.countersRead == 2)
    }

    @Test func theFirstSampleIsNotTakenUntilTheIntervalAfterThePlayCall() {
        var rig = Rig()
        rig.progress.take(.opening)
        rig.advance()
        #expect(rig.state(at: 0.3) == .opening)
        #expect(rig.countersRead == 0)
        #expect(rig.state(at: 0.5) == .playing)
    }
}
