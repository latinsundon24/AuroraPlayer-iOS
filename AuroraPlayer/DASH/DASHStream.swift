import Foundation

/// 一条 DASH 码流（视频或音频）的选择结果与分片计算
final class DASHStream {

    enum Kind: String {
        case video
        case audio
    }

    let kind: Kind
    let representation: MPDRepresentation
    let adaptation: MPDAdaptation
    let period: MPDPeriod
    let template: MPDSegmentTemplate?
    let segmentList: MPDSegmentList?
    let initURL: URL?
    let baseURL: URL

    init(kind: Kind,
         representation: MPDRepresentation,
         adaptation: MPDAdaptation,
         period: MPDPeriod,
         template: MPDSegmentTemplate?,
         segmentList: MPDSegmentList?,
         initURL: URL?,
         baseURL: URL) {
        self.kind = kind
        self.representation = representation
        self.adaptation = adaptation
        self.period = period
        self.template = template
        self.segmentList = segmentList
        self.initURL = initURL
        self.baseURL = baseURL
    }

    var bandwidth: Int { representation.bandwidth }
    var codecs: String? { representation.codecs ?? adaptation.mimeType }
    var width: Int? { representation.width ?? adaptation.width }
    var height: Int? { representation.height ?? adaptation.height }

    var mimeType: String? { representation.mimeType ?? adaptation.mimeType }

    var language: String? { adaptation.lang }

    // MARK: - 分片

    struct Segment {
        let url: URL
        let duration: Double
        let time: Double
        let number: Int
        var name: String { "\(number)" }
    }

    /// 计算静态（点播）清单的全部分片
    func staticSegments() -> [Segment] {
        if let list = segmentList {
            let ts = list.timescale > 0 ? list.timescale : 1
            let dur = (list.duration ?? 0) / ts
            return list.urls.enumerated().map { index, media in
                let url = resolve(media) ?? baseURL
                return Segment(url: url,
                               duration: dur,
                               time: Double(index) * dur,
                               number: index + 1)
            }
        }
        guard let template = template else { return [] }

        let duration = period.duration ?? 0
        let ts = template.timescale > 0 ? template.timescale : 1

        if !template.timeline.isEmpty {
            var out: [Segment] = []
            for (position, entry) in expandedTimeline().enumerated() {
                let number = template.startNumber + position
                let urlString = expand(template.media ?? "", number: number, time: entry.t)
                guard let url = resolve(urlString) else { continue }
                out.append(Segment(url: url, duration: entry.d/ts, time: entry.t/ts, number: number))
            }
            return out
        }

        guard let segDuration = template.duration, segDuration > 0 else { return [] }
        let segSeconds = segDuration / ts
        let total = duration > 0 ? Int(ceil(duration / segSeconds)) : 0
        var out: [Segment] = []
        for i in 0..<max(0, total) {
            let number = template.startNumber + i
            let urlString = expand(template.media ?? "", number: number, time: (template.pto + Double(i) * segDuration))
            guard let url = resolve(urlString) else { continue }
            out.append(Segment(url: url, duration: segSeconds, time: Double(i) * segSeconds, number: number))
        }
        return out
    }

    /// 动态（直播）清单：返回当前可播窗口内、已经发布的分片
    func liveSegments(now: Date,
                      availabilityStart: Date?,
                      timeShiftBuffer: Double?,
                      maxCount: Int = 24) -> [Segment] {
        guard let template = template else {
            return Array(staticSegments().suffix(maxCount))
        }
        let ts = template.timescale > 0 ? template.timescale : 1
        let periodStart = period.start ?? 0
        let ast = availabilityStart ?? now
        let elapsed = now.timeIntervalSince(ast) - periodStart
        guard elapsed > 0 else { return [] }

        // 当前可用的媒体时间（秒，相对 Period）
        let ptoSeconds = template.pto / ts
        let liveEdge = elapsed - ptoSeconds

        var candidates: [Segment] = []

        if !template.timeline.isEmpty {
            let entries = expandedTimeline()
            var position = 0
            for entry in entries {
                let startSeconds = entry.t / ts - ptoSeconds
                let endSeconds = startSeconds + entry.d / ts
                let number = template.startNumber + position
                position += 1
                guard endSeconds <= liveEdge + 0.5 else { continue }
                if let tsb = timeShiftBuffer, startSeconds < liveEdge - tsb { continue }
                let urlString = expand(template.media ?? "", number: number, time: entry.t)
                guard let url = resolve(urlString) else { continue }
                candidates.append(Segment(url: url, duration: entry.d / ts, time: startSeconds, number: number))
            }
        } else if let segDuration = template.duration, segDuration > 0 {
            let segSeconds = segDuration / ts
            let lastIndex = Int(floor(elapsed / segSeconds)) - 1
            guard lastIndex >= 0 else { return [] }
            var firstIndex = 0
            if let tsb = timeShiftBuffer {
                firstIndex = max(0, lastIndex - Int(ceil(tsb / segSeconds)))
            }
            firstIndex = max(firstIndex, lastIndex - maxCount + 1)
            for i in firstIndex...lastIndex {
                let number = template.startNumber + i
                let urlString = expand(template.media ?? "", number: number, time: (template.pto + Double(i) * segDuration))
                guard let url = resolve(urlString) else { continue }
                candidates.append(Segment(url: url,
                                          duration: segSeconds,
                                          time: Double(i) * segSeconds,
                                          number: number))
            }
        }

        return Array(candidates.suffix(maxCount))
    }

    private func expandedTimeline() -> [(t: Double, d: Double)] {
        guard let template = template else { return [] }
        var out: [(t: Double, d: Double)] = []
        var current: Double = 0
        let periodEnd = (period.duration ?? 0) * (template.timescale > 0 ? template.timescale : 1)

        for entry in template.timeline {
            if entry.t > 0 { current = entry.t }
            let repeatCount = entry.r >= 0 ? entry.r + 1 : 1
            if entry.r < 0 {
                // r = -1：重复到 Period 结束
                var t = current
                var guardCount = 0
                while (periodEnd <= 0 || t + entry.d <= periodEnd) && guardCount < 5000 {
                    out.append((t, entry.d))
                    t += entry.d
                    guardCount += 1
                    if periodEnd <= 0 { break }
                }
                current = t
            } else {
                for _ in 0..<repeatCount {
                    out.append((current, entry.d))
                    current += entry.d
                }
            }
        }
        return out
    }

    // MARK: - URL 模板

    private func expand(_ template: String, number: Int, time: Double) -> String {
        guard !template.isEmpty else { return "" }
        var result = template
        result = result.replacingOccurrences(of: "$RepresentationID$", with: representation.id)
        result = result.replacingOccurrences(of: "$Bandwidth$", with: String(bandwidth))

        // $Number%05d$
        let pattern = "\\$(Number|Time)(%0(\\d+)d)?\\$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let ns = result as NSString
        let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let token = ns.substring(with: match.range(at: 1))
            var replacement: String
            if token == "Number" {
                replacement = String(number)
                if match.range(at: 3).location != NSNotFound, let width = Int(ns.substring(with: match.range(at: 3))) {
                    replacement = String(format: "%0\(width)d", number)
                }
            } else {
                replacement = String(Int64(time.rounded()))
            }
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }

    private func resolve(_ relative: String) -> URL? {
        guard !relative.isEmpty else { return baseURL }
        let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }
}
