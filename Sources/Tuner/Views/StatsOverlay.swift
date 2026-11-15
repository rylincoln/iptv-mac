import Observation
import SwiftUI
import TunerCore

/// ⌘I: a small panel of playback numbers over the video's corner.
struct StatsOverlay: View {
    let readout: StatsReadout

    var body: some View {
        let lines = Self.lines(readout.reading)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines, id: \.name) { line in row(line.name, line.value) }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
        .allowsHitTesting(false)
        // One element for VoiceOver: the label names the panel, and the value reads out every line,
        // which a label alone would hide.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playback stats")
        .accessibilityValue(lines.map { "\($0.name) \($0.value)" }.joined(separator: ", "))
    }

    private struct Line {
        let name: String
        let value: String
    }

    private static func lines(_ reading: StatsReading) -> [Line] {
        [
            Line(name: "Host", value: reading.host ?? "-"),
            Line(name: "Bitrate", value: bitrate(kbps: reading.inputKbps)),
            Line(name: "Buffer", value: "\(reading.bufferMs) ms"),
            Line(name: "Lost pictures", value: reading.lostPictures.formatted()),
            Line(name: "Reconnects", value: reading.reconnects.formatted()),
            Line(name: "Status", value: text(for: reading.status)),
        ]
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
