import XCTest
@testable import AuroraPlayer

final class HLSProxyTests: XCTestCase {

    private let proxyBase = "http://127.0.0.1:9000/tok/"

    private func target(of line: String) -> String? {
        guard let range = line.range(of: proxyBase) else { return nil }
        var rest = String(line[range.upperBound...])
        if let quote = rest.firstIndex(of: "\"") {
            rest = String(rest[..<quote])
        }
        return HLSProxy.Core.decode(rest)
    }

    func testEncodeRoundTrip() {
        let url = "https://cdn.example.com/live/chunk-1.ts?token=a&x=1"
        let encoded = HLSProxy.Core.encode(url)
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(HLSProxy.Core.decode(encoded), url)
    }

    func testRewriteMasterPlaylist() {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="a",URI="audio/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aud"
        video/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=400000
        https://cdn2.example.com/low.m3u8
        """
        let base = URL(string: "https://example.com/live/master.m3u8")!
        let output = HLSProxy.Core.rewritePlaylist(text, base: base, proxyBase: proxyBase)

        let mediaLine = output.components(separatedBy: "\n").first { $0.hasPrefix("#EXT-X-MEDIA") }!
        XCTAssertEqual(target(of: mediaLine), "https://example.com/live/audio/index.m3u8")

        let uris = output.components(separatedBy: "\n").filter { !$0.isEmpty && !$0.hasPrefix("#") }
        XCTAssertEqual(uris.count, 2)
        for uri in uris {
            XCTAssertTrue(uri.hasPrefix(proxyBase), uri)
        }
        XCTAssertEqual(target(of: uris[0]), "https://example.com/live/video/index.m3u8")
        XCTAssertEqual(target(of: uris[1]), "https://cdn2.example.com/low.m3u8")
    }

    func testRewriteMediaPlaylist() {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:6
        #EXT-X-MAP:URI="init.mp4"
        #EXT-X-KEY:METHOD=AES-128,URI="../keys/k1.bin"
        #EXTINF:6.0,
        seg-1.ts
        #EXTINF:6.0,
        https://cdn.example.com/seg-2.ts
        #EXT-X-ENDLIST
        """
        let base = URL(string: "https://example.com/live/hls/index.m3u8")!
        let output = HLSProxy.Core.rewritePlaylist(text, base: base, proxyBase: proxyBase)
        let lines = output.components(separatedBy: "\n")

        let mapLine = lines.first { $0.hasPrefix("#EXT-X-MAP") }!
        XCTAssertEqual(target(of: mapLine), "https://example.com/live/hls/init.mp4")

        let keyLine = lines.first { $0.hasPrefix("#EXT-X-KEY") }!
        XCTAssertEqual(target(of: keyLine), "https://example.com/live/keys/k1.bin")

        let segments = lines.filter { $0.hasSuffix(".ts") || $0.contains(proxyBase) && !$0.hasPrefix("#") }
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(target(of: segments[0]), "https://example.com/live/hls/seg-1.ts")
        XCTAssertEqual(target(of: segments[1]), "https://cdn.example.com/seg-2.ts")
    }

    func testUnknownSchemeKeptAsIs() {
        let text = """
        #EXTM3U
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://key-1"
        #EXTINF:6.0,
        seg-1.ts
        """
        let base = URL(string: "https://example.com/live/index.m3u8")!
        let output = HLSProxy.Core.rewritePlaylist(text, base: base, proxyBase: proxyBase)
        XCTAssertTrue(output.contains("URI=\"skd://key-1\""))
    }

    func testMimeTypes() {
        XCTAssertEqual(HLSProxy.Core.mimeType(for: URL(string: "https://a/b.m3u8")!, contentType: nil, data: Data()),
                       "application/vnd.apple.mpegurl")
        XCTAssertEqual(HLSProxy.Core.mimeType(for: URL(string: "https://a/b.ts")!, contentType: nil, data: Data()),
                       "video/mp2t")
        XCTAssertEqual(HLSProxy.Core.mimeType(for: URL(string: "https://a/b.m4s")!, contentType: nil, data: Data()),
                       "video/iso.segment")
        XCTAssertEqual(HLSProxy.Core.mimeType(for: URL(string: "https://a/b.mp4")!, contentType: nil, data: Data()),
                       "video/mp4")
        XCTAssertEqual(HLSProxy.Core.mimeType(for: URL(string: "https://a/key")!,
                                              contentType: "text/html; charset=utf-8",
                                              data: Data()), "application/octet-stream")
    }

    func testCertificateErrorDetection() {
        XCTAssertTrue(HTTPService.isCertificateError(NSError(domain: NSURLErrorDomain,
                                                             code: NSURLErrorServerCertificateUntrusted)))
        XCTAssertTrue(HTTPService.isCertificateError(NSError(domain: NSURLErrorDomain,
                                                             code: NSURLErrorSecureConnectionFailed)))
        XCTAssertFalse(HTTPService.isCertificateError(NSError(domain: NSURLErrorDomain, code: -1009)))
        XCTAssertFalse(HTTPService.isCertificateError(nil))
    }
}
