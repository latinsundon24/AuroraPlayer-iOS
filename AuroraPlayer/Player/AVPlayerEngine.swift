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
    @Published var playbackURL: String = ""
    @Published var playbackMode: String = "—"

    var onEnded: (() -> Void)?

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var failObserver: NSObjectProtocol?
    private var rate: Float = 1.0
    private var dash: DashPlayback?
    private var hlsProxy: HLSProxy?
    private var currentChannel: Channel?
    private var proxyAttempted = false
    /// 用户是否希望播放（DASH 准备完成后据此自动起播）
    private var wantsPlayback = false
    private var openToken = UUID()

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
                self.report(item: item)
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
        if let observer = failObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - 打开频道

    func open(_ channel: Channel) {
        stopCurrent()
        currentChannel = channel
        proxyAttempted = false
        let token = UUID()
        openToken = token
        errorMessage = nil
        isPreparing = false
        statusText = nil
        isLiveStream = false
        playbackURL = ""
        playbackMode = "—"

        let lower = channel.url.lowercased()
        if lower.hasPrefix("rtmp://") || lower.hasPrefix("rtmps://")
            || lower.hasPrefix("rtsp://") || lower.hasPrefix("udp://")
            || lower.hasPrefix("mms://") || lower.hasSuffix(".flv") {
            errorMessage = "该频道使用 AVPlayer 不支持的协议/封装（rtmp / rtsp / udp / flv）"
            playbackMode = "不支持"
            return
        }

        if channel.isDASH {
            isPreparing = true
            statusText = "正在解析 DASH 流…"
            playbackMode = "DASH（解密转本地 HLS）"
            Task {
                do {
                    let playback = try DashPlayback(channel: channel)
                    let url = try await playback.start()
                    // 期间用户可能已切台
                    guard self.openToken == token else {
                        playback.stop()
                        return
                    }
                    self.dash = playback
                    self.isLiveStream = playback.isLive
                    self.isPreparing = false
                    self.statusText = nil
                    self.load(url: url, headers: [:])
                } catch {
                    guard self.openToken == token else { return }
                    self.isPreparing = false
                    self.statusText = nil
                    self.errorMessage = error.localizedDescription
                }
            }
        } else if let url = URL(string: channel.url) {
            playbackMode = "HLS 直连"
            load(url: url, headers: channel.headers)
        } else {
            errorMessage = "地址无效"
        }
    }

    func stopCurrent() {
        openToken = UUID()
        hlsProxy?.stop()
        hlsProxy = nil
        proxyAttempted = false
        dash?.stop()
        dash = nil
        pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: - 加载

    func load(url: URL, headers: [String: String] = [:]) {
        playbackURL = url.absoluteString
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
        if let observer = failObserver {
            NotificationCenter.default.removeObserver(observer)
            failObserver = nil
        }
        statusObserver?.invalidate()

        let options: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = options.map { AVURLAsset(url: url, options: $0) } ?? AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        if wantsPlayback {
            player.playImmediately(atRate: rate)
        }

        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if item.status == .failed {
                    self.report(item: item)
                }
            }
        }

        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            guard let self, let item = note.object as? AVPlayerItem else { return }
            self.report(item: item)
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

    /// 给用户复制给开发者的一行行诊断信息
    var diagnosticsText: String {
        var lines: [String] = []
        lines.append("频道：\(currentChannel?.name ?? "—")")
        lines.append("地址：\(currentChannel?.url ?? "—")")
        lines.append("模式：\(playbackMode)")
        lines.append("播放 URL：\(playbackURL.isEmpty ? "—" : playbackURL)")
        if let item = player.currentItem {
            lines.append("Item：status=\(item.status.rawValue) tracks=\(item.tracks.count)")
            let seconds = item.duration.seconds
            lines.append("时长：\(seconds.isFinite && seconds > 0 ? String(format: "%.1f", seconds) : "未知/直播")")
        }
        if let errorMessage {
            lines.append("错误：\(errorMessage)")
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        lines.append("版本：\(version) (\(build))")
        return lines.joined(separator: "\n")
    }

    /// 把 AVFoundation 的原始错误暴露出来，便于定位（例如 ATS 拦截、分片 4xx/5xx）
    private func report(item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        let ns = item.error as NSError?
        var detail = ns?.localizedDescription ?? "无法播放该流（格式不支持或网络异常）"
        if let ns {
            detail += "［\(ns.domain) \(ns.code)］"
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                detail += "\n底层错误：\(underlying.domain) \(underlying.code) \(underlying.localizedDescription)"
            }
        }
        if let log = item.errorLog(), !log.events.isEmpty {
            let events = log.events.suffix(3).map {
                "status=\($0.errorStatusCode) domain=\($0.errorDomain) uri=\($0.uri ?? "-")"
            }.joined(separator: " | ")
            NSLog("[Aurora] AVPlayer errorLog: %@", events)
        }
        NSLog("[Aurora] AVPlayerItem failed: %@", String(describing: ns))
        if errorMessage != detail { errorMessage = detail }
        retryWithProxyIfNeeded(error: ns)
    }

    /// AVPlayer 自己无法放行异常证书：https 直连失败时改走本地代理，用 URLSession 取流。
    private func retryWithProxyIfNeeded(error: NSError?) {
        guard !proxyAttempted,
              let channel = currentChannel,
              !channel.isDASH else { return }
        if let error {
            let domain = error.domain
            let cert = HTTPService.isCertificateError(error)
            guard cert || domain == NSURLErrorDomain || domain == "CoreMediaErrorDomain" else { return }
        }
        proxyAttempted = true
        do {
            let proxy = try HLSProxy(channel: channel)
            hlsProxy = proxy
            playbackMode = "HLS 本地代理（放行异常证书）"
            errorMessage = nil
            NSLog("[Aurora] 改用 HLS 代理重试: %@", channel.url)
            load(url: proxy.entryURL, headers: [:])
        } catch {
            errorMessage = "代理启动失败：\(error.localizedDescription)"
        }
    }

    func play() {
        wantsPlayback = true
        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    func pause() {
        wantsPlayback = false
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
