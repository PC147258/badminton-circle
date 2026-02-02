import SwiftUI
import AVKit

// 独立的视频播放组件，可复用
struct VideoPlayerView: View {
    // 接收外部传入的AVPlayer（也可直接在内部硬编码，按需选择）
    var player: AVPlayer
    
    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                player.play()
            }
            .onDisappear {
                player.pause()
            }
    }
}

// 组件预览
struct VideoPlayerView_Previews: PreviewProvider {
    static var previews: some View {
        VideoPlayerView(player: AVPlayer(url: URL(string: "https://socratellresource.s3.eu-central-1.amazonaws.com/3209298-uhd_3840_2160_25fps.mp4")!))
    }
}
