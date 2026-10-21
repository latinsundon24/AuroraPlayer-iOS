import XCTest
import CryptoKit
@testable import AuroraPlayer

final class AuroraTests: XCTestCase {

    // MARK: - 内置演示

    func testBundledDemoOfflineClearKeyChannel() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "demo", withExtension: "m3u"),
                                "App 包内缺少 demo.m3u")
        let text = try String(contentsOf: url, encoding: .utf8)
        let channels = PlaylistParser.parse(text)
        let demo = try XCTUnwrap(channels.first { $0.url.hasPrefix("aurora-bundle://") })

        XCTAssertTrue(demo.isDASH)
        XCTAssertTrue(demo.hasClearKey)
        XCTAssertTrue(demo.url.hasSuffix("/demo-dash/stream.mpd"))
        XCTAssertEqual(demo.keys["feedf00deedeadbeeff0baadf00dd00d"], "00112233445566778899aabbccddeeff")

        let folder = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("demo-dash"))
        for relative in ["stream.mpd", "video/avc1/init.mp4", "video/avc1/seg-1.m4s", "video/avc1/seg-2.m4s"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(relative).path),
                          "内置演示缺少 \(relative)")
        }
    }

    // MARK: - 播放列表解析

    func testM3UParsing() {
        let text = """
        #EXTM3U

        #EXTINF:-1 group-title="测试" tvg-logo="https://example.com/logo.png" tvg-name="CK",ClearKey 频道
        #KODIPROP:inputstream.adaptive.manifest_type=mpd
        #KODIPROP:inputstream.adaptive.license_type=clearkey
        #KODIPROP:inputstream.adaptive.license_key=feedf00d-eede-adbe-eff0-baadf00dd00d:00112233445566778899aabbccddeeff
        #EXTVLCOPT:http-user-agent=TestUA/1.0
        #EXTVLCOPT:http-referrer=https://example.com/
        https://example.com/live/stream.mpd

        #EXTINF:-1,普通 HLS
        https://example.com/live/stream.m3u8
        """

        let channels = PlaylistParser.parse(text)
        XCTAssertEqual(channels.count, 2)

        let first = channels[0]
        XCTAssertEqual(first.name, "ClearKey 频道")
        XCTAssertEqual(first.group, "测试")
        XCTAssertEqual(first.logo, "https://example.com/logo.png")
        XCTAssertTrue(first.isDASH)
        XCTAssertTrue(first.hasClearKey)
        XCTAssertEqual(first.keys["feedf00deedeadbeeff0baadf00dd00d"], "00112233445566778899aabbccddeeff")
        XCTAssertEqual(first.headers["User-Agent"], "TestUA/1.0")
        XCTAssertEqual(first.headers["Referer"], "https://example.com/")

        let second = channels[1]
        XCTAssertFalse(second.isDASH)
        XCTAssertTrue(second.keys.isEmpty)
    }

    // MARK: - MPD 解析与分片展开

    func testMPDParsingAndSegments() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" xmlns:cenc="urn:mpeg:cenc:2013"
             type="static" mediaPresentationDuration="PT12S">
          <Period id="0" duration="PT12S">
            <AdaptationSet contentType="video" mimeType="video/mp4">
              <ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011" value="cenc"
                                 cenc:default_KID="feedf00d-eede-adbe-eff0-baadf00dd00d"/>
              <SegmentTemplate timescale="1000" startNumber="1" duration="4000"
                               initialization="$RepresentationID$/init.mp4"
                               media="$RepresentationID$/seg-$Number$.m4s"/>
              <Representation id="video/avc1" bandwidth="300000" codecs="avc1.64001E"
                              width="640" height="360"/>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let document = try XCTUnwrap(MPDParser.parse(data: Data(xml.utf8)))
        XCTAssertFalse(document.isDynamic)
        XCTAssertEqual(document.mediaPresentationDuration ?? 0, 12, accuracy: 0.001)

        let period = try XCTUnwrap(document.periods.first)
        XCTAssertEqual(period.duration ?? 0, 12, accuracy: 0.001)
        let adaptation = try XCTUnwrap(period.adaptations.first)
        let representation = try XCTUnwrap(adaptation.representations.first)
        XCTAssertEqual(representation.codecs, "avc1.64001E")
        XCTAssertEqual(representation.protection.first?.kid, "feedf00d-eede-adbe-eff0-baadf00dd00d")

        let baseURL = try XCTUnwrap(URL(string: "https://example.com/dash/"))
        let stream = DASHStream(kind: .video,
                                representation: representation,
                                adaptation: adaptation,
                                period: period,
                                template: adaptation.segmentTemplate,
                                segmentList: nil,
                                initURL: URL(string: "https://example.com/dash/video/avc1/init.mp4"),
                                baseURL: baseURL)

        let segments = stream.staticSegments()
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.map { $0.url.lastPathComponent },
                       ["seg-1.m4s", "seg-2.m4s", "seg-3.m4s"])
        XCTAssertEqual(segments[0].duration, 4, accuracy: 0.001)
        XCTAssertEqual(segments[0].time, 0, accuracy: 0.001)
        XCTAssertEqual(segments[2].time, 8, accuracy: 0.001)
    }

    func testSegmentTimelineExpansion() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT10S">
          <Period duration="PT10S">
            <AdaptationSet contentType="video" mimeType="video/mp4">
              <SegmentTemplate timescale="90000" initialization="init-$RepresentationID$.mp4"
                               media="chunk-$Time$.m4s">
                <SegmentTimeline>
                  <S t="0" d="180000" r="2"/>
                </SegmentTimeline>
              </SegmentTemplate>
              <Representation id="v1" bandwidth="1000000" codecs="avc1.4d401f" width="1280" height="720"/>
            </AdaptationSet>
          </Period>
        </MPD>
        """

        let document = try XCTUnwrap(MPDParser.parse(data: Data(xml.utf8)))
        let period = try XCTUnwrap(document.periods.first)
        let adaptation = try XCTUnwrap(period.adaptations.first)
        let representation = try XCTUnwrap(adaptation.representations.first)
        let baseURL = try XCTUnwrap(URL(string: "https://cdn.example.com/dash/stream.mpd"))

        let stream = DASHStream(kind: .video,
                                representation: representation,
                                adaptation: adaptation,
                                period: period,
                                template: adaptation.segmentTemplate,
                                segmentList: nil,
                                initURL: nil,
                                baseURL: baseURL)
        let segments = stream.staticSegments()
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].url.lastPathComponent, "chunk-0.m4s")
        XCTAssertEqual(segments[1].url.lastPathComponent, "chunk-180000.m4s")
        XCTAssertEqual(segments[2].url.lastPathComponent, "chunk-360000.m4s")
        XCTAssertEqual(segments[0].duration, 2, accuracy: 0.001)
    }

    // MARK: - ClearKey 解密 + init 重写（真实 Bento4 加密样本）

    func testClearKeyDecryptionMatchesReference() throws {
        let keyHex = "00112233445566778899aabbccddeeff"
        let kid = "feedf00deedeadbeeff0baadf00dd00d"

        let initData = try fixture("init.mp4")
        let info = MP4Crypto.initInfo(from: initData)
        XCTAssertTrue(info.isProtected)
        XCTAssertEqual(info.defaultKID, kid)
        XCTAssertEqual(info.ivSize, 16)
        XCTAssertEqual(info.schemeType.lowercased(), "cenc")

        let encrypted = try fixture("seg-1.m4s")
        let track = MP4Fragment.parse(encrypted, defaults: info)
        XCTAssertEqual(track.sampleSizes.count, 250)
        XCTAssertEqual(track.crypto.count, 250)
        XCTAssertEqual(track.sampleSizes.reduce(0, +) + track.dataOffset, encrypted.count)

        let decrypted = try CENC.decrypt(fragment: encrypted,
                                         track: track,
                                         info: info,
                                         keys: [kid: keyHex])
        XCTAssertEqual(sha256(decrypted), "e39233dfd4300a7e5fd77191ebdb35f8f4d718b302fc7b15599957a491c1d323")

        let cleaned = MP4Fragment.stripAuxiliaryBoxes(decrypted)
        XCTAssertEqual(cleaned.count, 356371)
        XCTAssertEqual(sha256(cleaned), "e9e8276788cf604589d11cb76d970988b7b7c265f2f9d3c73c89be214b2a5df9")

        // 解密后的分片仍然能被正常解析（说明 trun.data_offset 修正正确）
        let reparsed = MP4Fragment.parse(cleaned, defaults: info)
        XCTAssertEqual(reparsed.sampleSizes.count, 250)
        XCTAssertEqual(reparsed.dataOffset + reparsed.sampleSizes.reduce(0, +), cleaned.count)

        let clearInit = MP4Crypto.stripEncryption(from: initData)
        XCTAssertEqual(clearInit.count, 696)
        XCTAssertEqual(sha256(clearInit), "0dab8988234ee2bfc0af2a33c69698e9d7e2f3699a28fe3c80f7a4b2df6d8950")
        XCTAssertFalse(clearInit.range(of: Data("sinf".utf8)) != nil)
    }

    func testMissingKeyThrows() throws {
        let initData = try fixture("init.mp4")
        let info = MP4Crypto.initInfo(from: initData)
        let encrypted = try fixture("seg-1.m4s")
        let track = MP4Fragment.parse(encrypted, defaults: info)
        XCTAssertThrowsError(try CENC.decrypt(fragment: encrypted,
                                             track: track,
                                             info: info,
                                             keys: [:]))
    }

    // MARK: - Helpers

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: AuroraTests.self)
        guard let url = bundle.url(forResource: name, withExtension: nil) else {
            throw XCTSkip("缺少测试样本 \(name)")
        }
        return try Data(contentsOf: url)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
