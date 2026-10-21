import XCTest
import AVFoundation
import QuartzCore
import CoreVideo

/// 回归测试：解密 + 去信令后的 fMP4，能否被 Apple 自己的 HLS 链路真正播放并解出画面。
/// （之前用 `AVURLAsset.loadTracks` 判断会得到 0 条轨道，因为 HLS 是惰性解析，必须真正起播。）
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

    // MARK: - 准备素材

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: AVFoundationPipelineTests.self)
        guard let url = bundle.url(forResource: name, withExtension: nil) else {
            throw XCTSkip("缺少测试样本 \(name)")
        }
        return try Data(contentsOf: url)
    }

    private func makeFiles() throws -> [String: Data] {
        let initData = try fixture("init.mp4")
        let info = MP4Crypto.initInfo(from: initData)
        XCTAssertTrue(info.isProtected, "初始化分片应带 CENC 信令")
        XCTAssertEqual(info.defaultKID, kid)

        var files: [String: Data] = [:]
        files["v-init.mp4"] = MP4Crypto.stripEncryption(from: initData)

        for (index, name) in ["seg-1.m4s", "seg-2.m4s"].enumerated() {
            let encrypted = try fixture(name)
            let track = MP4Fragment.parse(encrypted, defaults: info)
            let decrypted = try CENC.decrypt(fragment: encrypted, track: track, info: info, keys: [kid: key])
            files["vn\(index + 1).m4s"] = MP4Fragment.stripAuxiliaryBoxes(decrypted)
        }

        files["v.m3u8"] = Data("""
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:9
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-MAP:URI="v-init.mp4"
        #EXTINF:8.342,
        vn1.m4s
        #EXTINF:5.005,
        vn2.m4s
        #EXT-X-ENDLIST

        """.utf8)
        files["master.m3u8"] = Data("""
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-STREAM-INF:BANDWIDTH=347819,CODECS="avc1.64001E",RESOLUTION=640x360
        v.m3u8

        """.utf8)
        return files
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

    /// 真起播并抓解码帧
    private func play(url: URL, seconds: Double = 5) async -> (status: Int, width: Int, height: Int, frames: Int, error: String) {
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()

        var frames = 0
        var width = 0
        var height = 0
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            if output.hasNewPixelBuffer(forItemTime: time),
               let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                frames += 1
                if width == 0 {
                    width = CVPixelBufferGetWidth(buffer)
                    height = CVPixelBufferGetHeight(buffer)
                }
            }
        }
        player.pause()
        return (item.status.rawValue, width, height, frames, item.error.map { "\($0)" } ?? "nil")
    }

    // MARK: - 测试

    func testDecryptedHLSPlaysAndDecodesFrames() async throws {
        let port = try startServer(files: try makeFiles())
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/master.m3u8"))

        let result = await play(url: url)
        NSLog("[Aurora][TEST] status=%d size=%dx%d frames=%d error=%@",
              result.status, result.width, result.height, result.frames, result.error)

        XCTAssertEqual(result.status, AVPlayerItem.Status.readyToPlay.rawValue, "AVPlayerItem 未就绪：\(result.error)")
        XCTAssertEqual(result.width, 640, "解码帧宽度不对")
        XCTAssertEqual(result.height, 360, "解码帧高度不对")
        XCTAssertGreaterThanOrEqual(result.frames, 3, "没有解出画面帧")

        let requests = log.drain().joined(separator: "\n")
        XCTAssertTrue(requests.contains("v-init.mp4 -> 200"), "没有加载初始化分片：\n\(requests)")
        XCTAssertTrue(requests.contains("vn1.m4s -> 200"), "没有加载第一个分片：\n\(requests)")
        XCTAssertTrue(requests.contains("vn2.m4s -> 200"), "没有加载第二个分片：\n\(requests)")
    }

    func testDecryptedFMP4FilePlays() async throws {
        let files = try makeFiles()
        let combined = (files["v-init.mp4"] ?? Data())
            + (files["vn1.m4s"] ?? Data())
            + (files["vn2.m4s"] ?? Data())
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("aurora-fmp4-\(UUID().uuidString).mp4")
        try combined.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let result = await play(url: fileURL)
        XCTAssertEqual(result.status, AVPlayerItem.Status.readyToPlay.rawValue, "本地 fMP4 未就绪：\(result.error)")
        XCTAssertGreaterThanOrEqual(result.frames, 3, "本地 fMP4 没有解出画面帧")
    }

    /// 离线 DASH（file://）→ 解密 → 本地 HLS → AVPlayer，完整走一遍 App 里点“内置演示”的路径。
    func testOfflineFileDASHEndToEnd() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aurora-dash-\(UUID().uuidString)")
        let videoDir = dir.appendingPathComponent("video/avc1")
        try FileManager.default.createDirectory(at: videoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try fixture("init.mp4").write(to: videoDir.appendingPathComponent("init.mp4"))
        try fixture("seg-1.m4s").write(to: videoDir.appendingPathComponent("seg-1.m4s"))
        try fixture("seg-2.m4s").write(to: videoDir.appendingPathComponent("seg-2.m4s"))

        let mpd = """
        <?xml version="1.0" ?>
        <MPD xmlns:cenc="urn:mpeg:cenc:2013" xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-live:2011" minBufferTime="PT8.34S" mediaPresentationDuration="PT13.347S" type="static">
          <Period>
            <AdaptationSet mimeType="video/mp4" segmentAlignment="true" startWithSAP="1" maxWidth="640" maxHeight="360">
              <ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011" value="cenc" cenc:default_KID="feedf00d-eede-adbe-eff0-baadf00dd00d"/>
              <SegmentTemplate timescale="1000" duration="8342" initialization="$RepresentationID$/init.mp4" media="$RepresentationID$/seg-$Number$.m4s" startNumber="1"/>
              <Representation id="video/avc1" codecs="avc1.64001E" width="640" height="360" scanType="progressive" frameRate="30000/1001" bandwidth="347819"/>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        try mpd.write(to: dir.appendingPathComponent("stream.mpd"), atomically: true, encoding: .utf8)

        let channel = Channel(name: "内置演示",
                              url: dir.appendingPathComponent("stream.mpd").absoluteString,
                              manifestType: .dash,
                              licenseType: "clearkey",
                              keys: [kid: key])
        let playback = try DashPlayback(channel: channel)
        defer { playback.stop() }

        let localURL = try await playback.start()
        let result = await play(url: localURL, seconds: 5)
        NSLog("[Aurora][TEST] offline dash status=%d size=%dx%d frames=%d error=%@",
              result.status, result.width, result.height, result.frames, result.error)

        XCTAssertEqual(result.status, AVPlayerItem.Status.readyToPlay.rawValue, "DASH 转本地 HLS 未就绪：\(result.error)")
        XCTAssertEqual(result.width, 640)
        XCTAssertEqual(result.height, 360)
        XCTAssertGreaterThanOrEqual(result.frames, 3, "DASH 本地 HLS 没有解出画面帧")
    }
}
