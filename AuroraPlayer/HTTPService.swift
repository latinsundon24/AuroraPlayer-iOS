import Foundation
import CoreFoundation

enum HTTPService {

    static let defaultUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    struct Response {
        let data: Data
        let status: Int
        let headers: [String: String]
        let finalURL: URL?
    }

    enum Failure: LocalizedError {
        case badURL
        case transport(String)
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .badURL: return "地址无效"
            case .transport(let message): return "网络错误：\(message)"
            case .http(let code): return "HTTP \(code)"
            }
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// 同步拉文本（在后台线程调用）
    static func fetchSync(_ urlString: String, headers: [String: String] = [:]) throws -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<String, Error>!

        Task {
            do {
                let text = try await fetchText(urlString, headers: headers)
                result = .success(text)
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    static func fetchText(_ urlString: String, headers: [String: String] = [:]) async throws -> String {
        let response = try await fetch(urlString, headers: headers)
        return decode(response.data)
    }

    static func fetch(_ urlString: String,
                      headers: [String: String] = [:],
                      range: (Int, Int)? = nil) async throws -> Response {
        guard let url = URL(string: urlString) else { throw Failure.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let (start, end) = range {
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw Failure.transport("无 HTTP 响应")
            }
            guard (200..<400).contains(http.statusCode) else {
                throw Failure.http(http.statusCode)
            }
            var headerFields: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headerFields[String(describing: key)] = String(describing: value)
            }
            return Response(data: data,
                            status: http.statusCode,
                            headers: headerFields,
                            finalURL: http.url)
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
    }

    /// UTF-8 优先，失败回退 GB18030（兼容中文列表）
    static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) {
            return s
        }
        let gbRaw = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let s = String(data: data, encoding: String.Encoding(rawValue: gbRaw)) {
            return s
        }
        return String(decoding: data, as: UTF8.self)
    }
}
