import XCTest
import AVFoundation
import QuartzCore
import CoreVideo

/// 用 AVFoundation 真正起播我们生成的 HLS（解密 + 去信令 + fMP4），
/// 并抓取解码后的像素帧——验证 Apple 的解码链路能不能吃。
final class AVFoundationPipelineTests: XCTestCase {

    private var server: LocalHTTPServer?
    private let log = RequestLog()

    private let kid = "feedf00deedeadbeeff0baadf00dd00d"
    private let key = "00112233445566778899aabbccddeeff"

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []

        func add(_ text: String) {
            lock.lock()
            entries.append(text)
            lock.unlock()
        }

        func drain() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            let copy = entries
            entries.removeAll()
            return copy
        }
    }

    // MARK: - 样本

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: AVFoundationPipelineTests.self)
        guard let url = bundle.url(forResource: name, withExtension: nil) else {
            throw XCTSkip("缺少测试样本 \(name)")
        }
        return try Data(contentsOf: url)
    }

    private struct Pieces {
        var initSegment: Data
        var segments: [Data]
    }

    private func makePieces() throws -> Pieces {
        let initData = try fixture("init.mp4")
        let info = MP4Crypto.initInfo(from: initData)
        XCTAssertTrue(info.isProtected)
        XCTAssertEqual(info.defaultKID, kid)

        var segments: [Data] = []
        for name in ["seg-1.m4s", "seg-2.m4s"] {
            let encrypted = try fixture(name)
            let track = MP4Fragment.parse(encrypted, defaults: info)
            let decrypted = try CENC.decrypt(fragment: encrypted, track: track, info: info, keys: [kid: key])
            segments.append(MP4Fragment.stripAuxiliaryBoxes(decrypted))
        }
        return Pieces(initSegment: MP4Crypto.stripEncryption(from: initData), segments: segments)
    }

    // MARK: - 封装

    private func withBrand(_ data: Data, _ brand: String) -> Data {
        var bytes = [UInt8](data)
        let tag = Array(brand.utf8)
        guard bytes.count >= 20, tag.count == 4 else { return data }
        bytes.replaceSubrange(8..<12, with: tag)
        bytes.replaceSubrange(16..<20, with: tag)
        return Data(bytes)
    }

    private func withStyp(_ segment: Data) -> Data {
        var payload = Data("msdh".utf8)
        payload.append(Data([0, 0, 0, 0]))
        payload.append(Data("msdh".utf8))
        payload.append(Data("msix".utf8))
        var box = Data()
        var size = UInt32(8 + payload.count).bigEndian
        withUnsafeBytes(of: &size) { box.append(contentsOf: $0) }
        box.append(Data("styp".utf8))
        box.append(payload)
        box.append(segment)
        return box
    }

    private func mediaPlaylist(_ tag: String, durations: [Double]) -> String {
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:9\n#EXT-X-MEDIA-SEQUENCE:0\n"
        text += "#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MAP:URI=\"\(tag)-init.mp4\"\n"
        for (index, duration) in durations.enumerated() {
            text += "#EXTINF:\(String(format: "%.3f", duration)),\n\(tag)-n\(index + 1).m4s\n"
        }
        text += "#EXT-X-ENDLIST\n"
        return text
    }

    private func masterPlaylist(_ tag: String) -> String {
        "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"
            + "#EXT-X-STREAM-INF:BANDWIDTH=347819,CODECS=\"avc1.64001E\",RESOLUTION=640x360\n"
            + "\(tag)-v.m3u8\n"
    }

    private func startServer(files: [String: Data]) throws -> UInt16 {
        let logger = log
        let server = try LocalHTTPServer { path, _ in
            let name = path.split(separator: "/").last.map(String.init) ?? ""
            guard let data = files[name] else {
                logger.add("\(path) -> 404")
                return (404, "text/plain", Data())
            }
            let mime: String
            if name.hasSuffix(".m3u8") {
                mime = "application/vnd.apple.mpegurl"
            } else if name.hasSuffix(".mp4") {
                mime = "video/mp4"
            } else {
                mime = "video/iso.segment"
            }
            logger.add("\(path) -> 200 \(data.count)")
            return (200, mime, data)
        }
        self.server = server
        return server.port
    }

    /// 真起播：等 readyToPlay，抓解码帧
    private func play(url: URL, label: String, seconds: Double = 6) async -> String {
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()

        var frames = 0
        var firstFrameSize = CGSize.zero
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: time),
               let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                frames += 1
                if firstFrameSize == .zero {
                    firstFrameSize = CGSize(width: CVPixelBufferGetWidth(buffer),
                                            height: CVPixelBufferGetHeight(buffer))
                }
            }
        }
        player.pause()

        let duration = item.duration.seconds
        let size = item.presentationSize
        let error = item.error.map { "\($0)" } ?? "nil"
        return "\(label): status=\(item.status.rawValue) itemTracks=\(item.tracks.count)"
            + " size=\(Int(size.width))x\(Int(size.height))"
            + " frames=\(frames) frameSize=\(Int(firstFrameSize.width))x\(Int(firstFrameSize.height))"
            + " duration=\(String(format: "%.2f", duration.isFinite ? duration : -1)) error=\(error)"
    }

    // MARK: - 诊断

    func testPlaybackVariants() async throws {
        let pieces = try makePieces()
        let durations = [8.342, 5.005]
        var files: [String: Data] = [:]

        let variants: [(String, Data, [Data])] = [
            ("base", pieces.initSegment, pieces.segments),
            ("iso6styp", withBrand(pieces.initSegment, "iso6"), pieces.segments.map(withStyp))
        ]

        for (tag, initSegment, segments) in variants {
            files["\(tag)-init.mp4"] = initSegment
            for (index, segment) in segments.enumerated() {
                files["\(tag)-n\(index + 1).m4s"] = segment
            }
            files["\(tag)-v.m3u8"] = Data(mediaPlaylist(tag, durations: durations).utf8)
            files["\(tag)-master.m3u8"] = Data(masterPlaylist(tag).utf8)
        }

        let port = try startServer(files: files)
        var results: [String] = []

        for (tag, _, _) in variants {
            _ = log.drain()
            let url = URL(string: "http://127.0.0.1:\(port)/\(tag)-master.m3u8")!
            let result = await play(url: url, label: "hls-\(tag)")
            results.append(result)
            NSLog("[Aurora][DIAG] %@", result)
            for entry in log.drain() {
                NSLog("[Aurora][DIAG]   %@", entry)
            }
        }

        // 整段 fMP4 当本地文件播（确认容器/解码本身没问题）
        let combined = pieces.initSegment + pieces.segments.reduce(Data(), +)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("aurora-full-fmp4.mp4")
        try combined.write(to: fileURL)
        _ = log.drain()
        let fileResult = await play(url: fileURL, label: "file-fmp4")
        results.append(fileResult)
        NSLog("[Aurora][DIAG] %@", fileResult)

        XCTAssertTrue(results.contains { $0.hasPrefix("file-fmp4") && $0.contains("frames=") && !$0.contains("frames=0") },
                      "本地 fMP4 都解不出帧：\n" + results.joined(separator: "\n"))
        XCTAssertTrue(results.contains { $0.hasPrefix("hls-base") && !$0.contains("frames=0") },
                      "本地 fMP4 能解，但 HLS 封装解不出帧：\n" + results.joined(separator: "\n"))
    }
}
