import SwiftUI
import AVFoundation
import UIKit

struct PlayerScreen: View {

    let channels: [Channel]
    let sourceName: String

    @StateObject private var engine = AVPlayerEngine()
    @State private var index: Int
    @State private var aspectIndex: Int = 0
    @State private var speedIndex: Int = 2
    @State private var showSettings = false
    @State private var showChannels = false
    @State private var controlsVisible = true

    private let aspects: [(String, AVLayerVideoGravity)] = [
        ("自适应", .resizeAspect),
        ("全屏填充", .resizeAspectFill),
        ("拉伸铺满", .resize)
    ]
    private let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    private let speedNames = ["0.5x", "0.75x", "1.0x", "1.25x", "1.5x", "2.0x"]

    init(channels: [Channel], startIndex: Int, sourceName: String) {
        self.channels = channels
        self.sourceName = sourceName
        let safe = channels.isEmpty ? 0 : max(0, min(startIndex, channels.count - 1))
        _index = State(initialValue: safe)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoSurface(player: engine.player, gravity: aspects[aspectIndex].1)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        controlsVisible.toggle()
                    }
                }

            if engine.isPreparing {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.4)
                    Text(engine.statusText ?? "正在准备…")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(22)
                .background(Color.black.opacity(0.55))
                .cornerRadius(14)
            }

            if let message = engine.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 34))
                        .foregroundColor(.orange)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 30)
                    Button("重新加载") {
                        loadCurrent()
                    }
                    .padding(.top, 4)
                }
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                if controlsVisible {
                    bottomBar
                }
            }
        }
        .statusBarHidden(true)
        .onAppear {
            engine.onEnded = { nextChannel(auto: true) }
            engine.setRate(speeds[speedIndex])
            loadCurrent()
        }
        .onDisappear {
            engine.pause()
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showChannels) { channelSheet }
    }

    // MARK: - 播放

    private var currentChannel: Channel? {
        guard index >= 0 && index < channels.count else { return nil }
        return channels[index]
    }

    private func loadCurrent() {
        guard let channel = currentChannel else { return }
        engine.setRate(speeds[speedIndex])
        engine.open(channel)
        engine.play()
    }

    private func nextChannel(auto: Bool) {
        if index + 1 < channels.count {
            index += 1
            loadCurrent()
        } else if auto {
            engine.pause()
        }
    }

    private func prevChannel() {
        if index > 0 {
            index -= 1
            loadCurrent()
        }
    }

    // MARK: - 覆盖层

    private var topBar: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(currentChannel?.name ?? "—")
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(sourceName)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer()
            Text("\(aspects[aspectIndex].0) · \(speedNames[speedIndex])")
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [Color.black.opacity(0.75), Color.black.opacity(0.0)]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            controlButton(engine.isPlaying ? "pause.fill" : "play.fill") {
                engine.toggle()
            }
            controlButton("backward.end.fill") {
                prevChannel()
            }
            controlButton("forward.end.fill") {
                nextChannel(auto: false)
            }

            Spacer(minLength: 6)

            Text(timeText)
                .font(.caption.monospacedDigit())
                .foregroundColor(.white.opacity(0.75))

            Spacer(minLength: 6)

            controlButton("list.bullet") {
                showChannels = true
            }
            controlButton("slider.horizontal.3") {
                showSettings = true
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [Color.black.opacity(0.0), Color.black.opacity(0.82)]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private var timeText: String {
        "\(format(engine.currentTime)) / \(format(engine.duration))"
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    private func controlButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 46, height: 40)
                .background(Color.white.opacity(0.16))
                .cornerRadius(10)
        }
    }

    // MARK: - 设置面板

    private var settingsSheet: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        Text("播放内核")
                        Spacer()
                        Text("AVPlayer").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("解码方式")
                        Spacer()
                        Text("硬解 / 自动回退").foregroundColor(.secondary)
                    }
                    HStack {
                        Text("当前频道")
                        Spacer()
                        Text(currentChannel?.name ?? "—")
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                } header: {
                    Text("播放")
                } footer: {
                    Text("DASH/ClearKey 频道由 App 内解密并转为本地 HLS 后播放；HLS 频道直接交给系统 AVPlayer。")
                }

                Section {
                    Text(engine.diagnosticsText)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = engine.diagnosticsText
                    } label: {
                        Text("复制诊断信息")
                    }
                } header: {
                    Text("诊断")
                } footer: {
                    Text("播放异常时请复制这里的内容发给开发者，可看到真实地址、播放模式与系统错误码。")
                }

                Section(header: Text("屏幕比例")) {
                    ForEach(0..<aspects.count, id: \.self) { i in
                        Button {
                            aspectIndex = i
                        } label: {
                            HStack {
                                Text(aspects[i].0).foregroundColor(.primary)
                                Spacer()
                                if aspectIndex == i {
                                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                }

                Section(header: Text("播放速度")) {
                    ForEach(0..<speeds.count, id: \.self) { i in
                        Button {
                            speedIndex = i
                            engine.setRate(speeds[i])
                        } label: {
                            HStack {
                                Text(speedNames[i]).foregroundColor(.primary)
                                Spacer()
                                if speedIndex == i {
                                    Image(systemName: "checkmark").foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        showSettings = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            showChannels = true
                        }
                    } label: {
                        Text("频道列表（\(channels.count)）")
                    }
                    Button {
                        loadCurrent()
                    } label: {
                        Text("重新加载当前频道")
                    }
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showSettings = false }
                }
            }
        }
    }

    // MARK: - 频道列表

    private var channelSheet: some View {
        NavigationView {
            List {
                ForEach(Array(channels.enumerated()), id: \.element.id) { idx, channel in
                    Button {
                        index = idx
                        loadCurrent()
                        showChannels = false
                    } label: {
                        HStack {
                            Text(channel.name)
                                .foregroundColor(idx == index ? .accentColor : .primary)
                                .lineLimit(1)
                            Spacer()
                            Text(channel.group)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(sourceName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showChannels = false }
                }
            }
        }
    }
}
