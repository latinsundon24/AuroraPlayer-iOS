import XCTest
import AVFoundation

/// 用 AVFoundation 真正加载并解码我们生成的 HLS（解密 + 去信令 + fMP4），
/// 验证的不是“VLC 能播”，而是 Apple 自己的解析器能不能吃。
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

    private func mediaPlaylist(_ tag: String, durations: [Double], extraTags: String = "") -> String {
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:9\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        if !extraTags.isEmpty { text += extraTags + "\n" }
        text += "#EXT-X-MAP:URI=\"\(tag)-init.mp4\"\n"
        for (index, duration) in durations.enumerated() {
            text += "#EXTINF:\(String(format: "%.3f", duration)),\n\(tag)-n\(index + 1).m4s\n"
        }
        text += "#EXT-X-ENDLIST\n"
        return text
    }

    private func masterPlaylist(_ tag: String, codecs: Bool = true, independent: Bool = true) -> String {
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n"
        if independent { text += "#EXT-X-INDEPENDENT-SEGMENTS\n" }
        if codecs {
            text += "#EXT-X-STREAM-INF:BANDWIDTH=347819,CODECS=\"avc1.64001E\",RESOLUTION=640x360\n"
        } else {
            text += "#EXT-X-STREAM-INF:BANDWIDTH=347819,RESOLUTION=640x360\n"
        }
        text += "\(tag)-v.m3u8\n"
        return text
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

    private func probe(port: UInt16, path: String, label: String) async -> String {
        let url = URL(string: "http://127.0.0.1:\(port)/\(path)")!
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let duration = try await asset.load(.duration)
            return "\(label): tracks=\(tracks.count) duration=\(String(format: "%.2f", duration.seconds))"
        } catch {
            return "\(label): error \(error)"
        }
    }

    // MARK: - 诊断

    func testDiagnoseContainerVariants() async throws {
        let pieces = try makePieces()
        let durations = [8.342, 5.005]
        var files: [String: Data] = [:]

        struct Variant {
            var tag: String
            var initSegment: Data
            var segments: [Data]
            var master: Bool
            var codecs: Bool = true
            var independent: Bool = true
            var extraTags: String = ""
        }

        let variants: [Variant] = [
            Variant(tag: "base", initSegment: pieces.initSegment, segments: pieces.segments, master: true),
            Variant(tag: "direct", initSegment: pieces.initSegment, segments: pieces.segments, master: false),
            Variant(tag: "nocodecs", initSegment: pieces.initSegment, segments: pieces.segments, master: true, codecs: false),
            Variant(tag: "noindep", initSegment: pieces.initSegment, segments: pieces.segments, master: true, independent: false),
            Variant(tag: "iso6styp", initSegment: withBrand(pieces.initSegment, "iso6"),
                    segments: pieces.segments.map(withStyp), master: true),
            Variant(tag: "plain", initSegment: pieces.initSegment, segments: pieces.segments, master: true,
                    extraTags: "#EXT-X-DISCONTINUITY-SEQUENCE:0")
        ]

        for variant in variants {
            files["\(variant.tag)-init.mp4"] = variant.initSegment
            for (index, segment) in variant.segments.enumerated() {
                files["\(variant.tag)-n\(index + 1).m4s"] = segment
            }
            files["\(variant.tag)-v.m3u8"] = Data(mediaPlaylist(variant.tag, durations: durations,
                                                               extraTags: variant.extraTags).utf8)
            files["\(variant.tag)-master.m3u8"] = Data(masterPlaylist(variant.tag, codecs: variant.codecs,
                                                                      independent: variant.independent).utf8)
        }

        let port = try startServer(files: files)
        var results: [String] = []
        for variant in variants {
            _ = log.drain()
            let path = variant.master ? "\(variant.tag)-master.m3u8" : "\(variant.tag)-v.m3u8"
            let result = await probe(port: port, path: path, label: variant.tag)
            results.append(result)
            NSLog("[Aurora][DIAG] %@", result)
            for entry in log.drain() {
                NSLog("[Aurora][DIAG]   %@", entry)
            }
        }

        let combined = pieces.initSegment + pieces.segments.reduce(Data(), +)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("aurora-full-fmp4.mp4")
        try combined.write(to: fileURL)
        do {
            let fileAsset = AVURLAsset(url: fileURL)
            let tracks = try await fileAsset.loadTracks(withMediaType: .video)
            let duration = try await fileAsset.load(.duration)
            let line = "file-fmp4: tracks=\(tracks.count) duration=\(String(format: "%.2f", duration.seconds))"
            results.append(line)
            NSLog("[Aurora][DIAG] %@", line)
        } catch {
            let line = "file-fmp4: error \(error)"
            results.append(line)
            NSLog("[Aurora][DIAG] %@", line)
        }

        XCTAssertTrue(results.contains { $0.contains("tracks=1") },
                      "没有任何封装形态被 AVFoundation 接受：\n" + results.joined(separator: "\n"))
    }
}
