import Foundation
import Combine

/// 播放列表与频道的本地持久化（UserDefaults + JSON）
final class Store: ObservableObject {

    static let shared = Store()

    @Published var sources: [Source] = []

    private let defaults = UserDefaults.standard
    private let sourcesKey = "aurora.sources"
    private let channelsPrefix = "aurora.channels."
    private let demoVersionKey = "aurora.demoVersion"
    /// 内置示例的内容版本：升级后把老用户的内置线路也换成新的（例如离线 ClearKey 演示）
    private let demoVersion = 2

    private init() {
        load()
        seedIfNeeded()
    }

    // MARK: - sources

    private func load() {
        guard let data = defaults.data(forKey: sourcesKey),
              let list = try? JSONDecoder().decode([Source].self, from: data) else {
            return
        }
        sources = list
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(sources) {
            defaults.set(data, forKey: sourcesKey)
        }
    }

    func add(_ source: Source) {
        sources.append(source)
        persist()
    }

    func update(_ source: Source) {
        if let i = sources.firstIndex(where: { $0.id == source.id }) {
            sources[i] = source
            persist()
        }
    }

    func remove(_ source: Source) {
        sources.removeAll { $0.id == source.id }
        defaults.removeObject(forKey: channelsPrefix + source.id.uuidString)
        persist()
    }

    // MARK: - channels

    func channels(for source: Source) -> [Channel] {
        guard let data = defaults.data(forKey: channelsPrefix + source.id.uuidString),
              let list = try? JSONDecoder().decode([Channel].self, from: data) else {
            return []
        }
        return list
    }

    func save(channels: [Channel], for source: Source) {
        if let data = try? JSONEncoder().encode(channels) {
            defaults.set(data, forKey: channelsPrefix + source.id.uuidString)
        }
    }

    // MARK: - 内置示例

    private func seedIfNeeded() {
        guard defaults.integer(forKey: demoVersionKey) < demoVersion else { return }
        guard let url = Bundle.main.url(forResource: "demo", withExtension: "m3u"),
              let data = try? Data(contentsOf: url) else {
            return
        }
        let channels = PlaylistParser.parse(HTTPService.decode(data))
        guard !channels.isEmpty else { return }

        if let index = sources.firstIndex(where: { $0.kind == .asset && $0.location == "demo.m3u" }) {
            // 老版本安装过：原地更新内置线路内容（用户自己的线路不受影响）
            var source = sources[index]
            save(channels: channels, for: source)
            source.count = channels.count
            sources[index] = source
            persist()
        } else if sources.isEmpty {
            var source = Source(name: "内置示例线路", kind: .asset, location: "demo.m3u")
            source.count = channels.count
            save(channels: channels, for: source)
            sources = [source]
            persist()
        }
        defaults.set(demoVersion, forKey: demoVersionKey)
    }
}
