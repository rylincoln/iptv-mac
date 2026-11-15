import Observation
import SwiftUI
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

/// ⌘I: a small panel of playback numbers over the video's corner.
struct StatsOverlay: View {
    let readout: StatsReadout

    var body: some View {
        let reading = readout.reading
        VStack(alignment: .leading, spacing: 2) {
            row("Host", reading.host ?? "-")
            row("Bitrate", Self.bitrate(kbps: reading.inputKbps))
            row("Buffer", "\(reading.bufferMs) ms")
            row("Lost pictures", reading.lostPictures.formatted())
            row("Reconnects", reading.reconnects.formatted())
            row("Status", Self.text(for: reading.status))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playback stats")
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(name).foregroundStyle(.white.opacity(0.7))
            Spacer(minLength: 12)
            Text(value)
        }
        .frame(minWidth: 190)
    }

    static func bitrate(kbps: Int) -> String {
        kbps >= 1000 ? String(format: "%.1f Mb/s", Double(kbps) / 1000) : "\(kbps) kb/s"
    }

    static func text(for status: PlaybackSupervisor.Status) -> String {
        switch status {
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .playing: return "Playing"
        case .reconnecting(let attempt): return "Reconnecting (\(attempt))"
        case .unavailable: return "Unavailable"
        }
    }
}
