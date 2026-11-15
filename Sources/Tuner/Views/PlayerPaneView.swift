import SwiftUI
import TunerCore

struct PlayerPaneView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.black
                VideoView(videoView: model.videoView)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)

            Text(model.playingChannel?.name ?? "Nothing playing")
                .font(.title3.weight(.semibold))
                .foregroundStyle(model.playingChannel == nil ? .secondary : .primary)
                .lineLimit(2)
                .padding()

            Spacer(minLength: 0)
        }
    }
}
