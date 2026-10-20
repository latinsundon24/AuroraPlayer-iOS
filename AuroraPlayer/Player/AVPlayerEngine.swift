import Foundation
import AVFoundation
import Combine

/// AVPlayer 播放内核（iOS 系统硬解 + 自动回退）
final class AVPlayerEngine: ObservableObject {

    let player = AVPlayer()

    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var errorMessage: String?

    var onEnded: (() -> Void)?

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var rate: Float = 1.0

    init() {
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = true

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self else { return }
            self.currentTime = time.seconds.isFinite ? time.seconds : 0
            self.isPlaying = self.player.rate > 0

            guard let item = self.player.currentItem else { return }
            let d = item.duration.seconds
            if d.isFinite && d > 0 {
                self.duration = d
            }
            if item.status == .failed {
                let msg = item.error?.localizedDescription ?? "播放失败（格式不支持或网络异常）"
                if self.errorMessage != msg {
                    self.errorMessage = msg
                }
            }
        }
    }

    deinit {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func load(_ urlString: String) {
        errorMessage = nil
        currentTime = 0
        duration = 0

        guard let url = URL(string: urlString) else {
            errorMessage = "地址无效"
            return
        }

        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.onEnded?()
        }
    }

    func play() {
        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func toggle() {
        if player.rate > 0 {
            pause()
        } else {
            play()
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func setRate(_ value: Float) {
        rate = value
        if player.rate > 0 {
            player.rate = value
        }
    }
}
