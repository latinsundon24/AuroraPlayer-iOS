import Foundation
import CoreFoundation

enum HTTPService {

    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    /// 同步拉取（在后台线程调用）
    static func fetchSync(_ urlString: String) throws -> String {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        var failure: Error?
        var status: Int = 0

        URLSession.shared.dataTask(with: request) { data, response, error in
            payload = data
            failure = error
            if let http = response as? HTTPURLResponse {
                status = http.statusCode
            }
            semaphore.signal()
        }.resume()

        semaphore.wait()

        if let failure = failure {
            throw failure
        }
        guard let data = payload else {
            throw URLError(.unknown)
        }
        if status != 0 && !(200..<300).contains(status) {
            throw NSError(domain: "AuroraHTTP",
                          code: status,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"])
        }
        return decode(data)
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
