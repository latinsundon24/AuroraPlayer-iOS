import Foundation

/// 一个可播放的频道条目
struct Channel: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var url: String
    var group: String = "默认"

    init(id: UUID = UUID(), name: String, url: String, group: String = "默认") {
        self.id = id
        self.name = name
        self.url = url
        self.group = group
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
