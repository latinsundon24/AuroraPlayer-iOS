import XCTest
import AVFoundation

/// 用 AVFoundation 真正加载并解码我们生成的 HLS（解密 + 去信令 + fMP4），
/// 验证的不是“VLC 能播”，而是 Apple 自己的解析器能不能吃。
final class AVFoundationPipelineTests: XCTestCase {

    private var server: LocalHTTPServer?

    private let kid = "feedf00deedeadbeeff0baadf00dd00d"
    private let key = "00112233445566778899aabbccddeeff"

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: AVFoundationPipelineTests.self)
        guard let url = bundle.url(forResource: name, withExtension: nil) else {
            throw XCTSkip("缺少测试样本 \(name)")
        }
        return try Data(contentsOf: url)
    }

    /// 复刻 DashPlayback 的输出格式
    private func mediaPlaylist() -> String {
        """
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
        """
    }

    private func masterPlaylist() -> String {
        """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-STREAM-INF:BANDWIDTH=347819,CODECS="avc1.64001E",RESOLUTION=640x360
        v.m3u8
        """
    }

    /// 生成产物：init 去信令、分片解密 + 去 senc/saiz/saio
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

        files["v.m3u8"] = Data(mediaPlaylist().utf8)
        files["master.m3u8"] = Data(masterPlaylist().utf8)
        return files
    }

    private func startServer(files: [String: Data]) throws -> URL {
        let server = try LocalHTTPServer { path, _ in
            let name = path.split(separator: "/").last.map(String.init) ?? ""
            guard let data = files[name] else { return (404, "text/plain", Data()) }
            let mime: String
            if name.hasSuffix(".m3u8") {
                mime = "application/vnd.apple.mpegurl"
            } else if name.hasSuffix(".mp4") {
                mime = "video/mp4"
            } else {
                mime = "video/iso.segment"
            }
            return (200, mime, data)
        }
        self.server = server
        return try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/master.m3u8"))
    }

    func testAVFoundationAcceptsDecryptedHLS() async throws {
        let url = try startServer(files: try makeFiles())
        let asset = AVURLAsset(url: url)

        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable, "AVFoundation 认为该 HLS 不可播放")

        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 13.347, accuracy: 0.5)

        let tracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(tracks.first, "没有视频轨道")
        let size = try await videoTrack.load(.naturalSize)
        XCTAssertEqual(size.width, 640, accuracy: 0.5)
        XCTAssertEqual(size.height, 360, accuracy: 0.5)

        let nominal = try await videoTrack.load(.nominalFrameRate)
        XCTAssertGreaterThan(nominal, 20)
    }

    func testAVFoundationCanDecodeFrames() async throws {
        let url = try startServer(files: try makeFiles())
        let asset = AVURLAsset(url: url)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        for seconds in [0.5, 6.0, 11.0] {
            let result = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            XCTAssertEqual(result.image.width, 640)
            XCTAssertEqual(result.image.height, 360)
        }
    }
}
