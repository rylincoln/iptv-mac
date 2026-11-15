import Observation
import TunerCore

/// One reading of the numbers the overlay shows. Never holds more of the stream's address than its host.
struct StatsReading: Equatable {
    var host: String?
    var inputKbps = 0
    var bufferMs = 0
    var lostPictures = 0
    var reconnects = 0
    var status = PlaybackSupervisor.Status.idle
}

/// The overlay's own observable state: the model writes it once a second while the overlay shows, and
/// only `StatsOverlay` reads it, so the video and the lists are not rebuilt by it.
@MainActor @Observable final class StatsReadout {
    var reading = StatsReading()
}
