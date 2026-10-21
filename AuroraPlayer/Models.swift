import Foundation

/// 清单类型
enum ManifestType: String, Codable, Hashable {
    case auto
    case hls
    case dash
    case smooth
}

/// 一个可播放的频道，带 DRM / 请求头等元数据
struct Channel: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var url: String
    var group: String = "默认"
    var logo: String? = nil

    /// 来自 #KODIPROP:inputstream.adaptive.manifest_type
    var manifestType: ManifestType = .auto

    /// 来自 #KODIPROP:inputstream.adaptive.license_type
    var licenseType: String? = nil

    /// ClearKey：kid(hex) -> key(hex)
    var keys: [String: String] = [:]

    /// license_key 是 URL 的情况（远程取 key）
    var licenseURL: String? = nil

    /// 来自 #EXTVLCOPT / stream_headers
    var headers: [String: String] = [:]

    init(id: UUID = UUID(),
         name: String,
         url: String,
         group: String = "默认",
         logo: String? = nil,
         manifestType: ManifestType = .auto,
         licenseType: String? = nil,
         keys: [String: String] = [:],
         licenseURL: String? = nil,
         headers: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.url = url
        self.group = group
        self.logo = logo
        self.manifestType = manifestType
        self.licenseType = licenseType
        self.keys = keys
        self.licenseURL = licenseURL
        self.headers = headers
    }

    /// 是否需要走自研 DASH/CENC 管线
    var isDASH: Bool {
        if manifestType == .dash { return true }
        if manifestType == .hls { return false }
        let lower = url.lowercased()
        if lower.hasPrefix("file://") { return lower.hasSuffix(".mpd") }
        if lower.contains(".mpd") { return true }
        if lower.contains(".m3u8") || lower.contains("m3u8?") { return false }
        return false
    }

    var hasClearKey: Bool { !keys.isEmpty }

    var userAgent: String? {
        headers.first { $0.key.lowercased() == "user-agent" }?.value
    }
}

/// 一个播放列表来源（在线网址 / 本地文件 / 内置示例）
struct Source: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case url
        case file
        case asset
    }

    var id: UUID = UUID()
    var name: String
    var kind: Kind
    var location: String
    var count: Int = 0
    var updatedAt: Date = Date()

    init(id: UUID = UUID(), name: String, kind: Kind, location: String, count: Int = 0, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.location = location
        self.count = count
        self.updatedAt = updatedAt
    }

    var kindText: String {
        switch kind {
        case .url: return "在线"
        case .file: return "本地"
        case .asset: return "内置"
        }
    }
}
