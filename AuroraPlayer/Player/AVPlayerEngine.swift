import Foundation
import AVFoundation
import Combine

/// 播放内核：
///   - HLS / 本地文件  → AVPlayer 直连
///   - DASH / ClearKey → DashPlayback 解密转本地 HLS 后交给 AVPlayer
@MainActor
final class AVPlayerEngine: ObservableObject {

    let player = AVPlayer()

    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var errorMessage: String?
    @Published var isPreparing: Bool = false
    @Published var statusText: String?
    @Published var isLiveStream: Bool = false

    var onEnded: (() -> Void)?

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var rate: Float = 1.0
    private var dash: DashPlayback?

    init() {
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = true

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds.isFinite ? time.seconds : 0
            self.isPlaying = self.player.rate > 0
            guard let item = self.player.currentItem else { return }
            let d = item.duration.seconds
            if d.isFinite && d > 0 {
                self.duration = d
            }
            if item.status == .failed {
                let msg = item.error?.localizedDescription ?? "播放失败（格式不支持或网络异常）"
                if self.errorMessage != msg { self.errorMessage = msg }
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

    // MARK: - 打开频道

    func open(_ channel: Channel) {
        stopCurrent()
        errorMessage = nil
        isPreparing = false
        statusText = nil
        isLiveStream = false

        if channel.isDASH {
            isPreparing = true
            statusText = "正在解析 DASH 流…"
            Task {
                do {
                    let playback = try DashPlayback(channel: channel)
                    let url = try await playback.start()
                    self.dash = playback
                    self.isLiveStream = playback.isLive
                    self.load(url: url, headers: [:])
                    self.isPreparing = false
                    self.statusText = nil
                } catch {
                    self.isPreparing = false
                    self.statusText = nil
                    self.errorMessage = error.localizedDescription
                }
            }
        } else if let url = URL(string: channel.url) {
            load(url: url, headers: channel.headers)
        } else {
            errorMessage = "地址无效"
        }
    }

    func stopCurrent() {
        dash?.stop()
        dash = nil
        pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - 加载

    func load(url: URL, headers: [String: String] = [:]) {
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
        statusObserver?.invalidate()

        let options: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = options.map { AVURLAsset(url: url, options: $0) } ?? AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)

        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if item.status == .failed {
                    self.errorMessage = item.error?.localizedDescription ?? "无法播放该流"
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.onEnded?()
        }
    }

    // MARK: - 控制

    func play() {
        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func toggle() {
        if player.rate > 0 { pause() } else { play() }
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
