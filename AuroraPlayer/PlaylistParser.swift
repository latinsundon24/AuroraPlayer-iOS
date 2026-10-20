import Foundation

/// 容错解析 .m3u / .m3u8 / .txt 播放列表
///
/// 支持：
///   #EXTM3U
///   #EXTINF:-1 group-title="…" tvg-name="…",名称   + 下一行网址
///   #EXTGRP:分组
///   名称,网址    名称|网址    网址,名称    网址|名称
///   仅网址（自动从网址取名）
enum PlaylistParser {

    static func parse(_ content: String) -> [Channel] {
        var out: [Channel] = []
        var pendingName: String?
        var pendingGroup: String?

        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalized.components(separatedBy: "\n")

        for raw in lines {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("\u{FEFF}") {
                line = String(line.dropFirst())
            }

            if line.hasPrefix("#EXTINF") {
                if let comma = line.firstIndex(of: ",") {
                    pendingName = String(line[line.index(after: comma)...])
                        .trimmingCharacters(in: .whitespaces)
                } else {
                    pendingName = ""
                }
                if let g = attribute(line, "group-title"), !g.isEmpty {
                    pendingGroup = g
                }
                if (pendingName ?? "").isEmpty, let n = attribute(line, "tvg-name"), !n.isEmpty {
                    pendingName = n
                }
                continue
            }

            if line.hasPrefix("#EXTGRP") {
                if let colon = line.firstIndex(of: ":") {
                    pendingGroup = String(line[line.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            if line.hasPrefix("#") { continue }

            var name: String?
            var url: String

            if let pn = pendingName, !pn.isEmpty {
                name = pn
                url = line
            } else if let sep = firstSeparator(line) {
                let a = String(line[..<sep]).trimmingCharacters(in: .whitespaces)
                let b = String(line[line.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
                if b.contains("://") {
                    name = a
                    url = b
                } else if a.contains("://") {
                    url = a
                    name = b
                } else {
                    name = a
                    url = b
                }
            } else {
                url = line
            }

            let group = (pendingGroup?.isEmpty == false) ? pendingGroup! : "默认"
            pendingName = nil
            pendingGroup = nil

            if url.isEmpty { continue }
            let finalName = (name?.isEmpty == false) ? name! : deriveName(url)
            out.append(Channel(name: finalName, url: url, group: group))
        }

        return out
    }

    private static func firstSeparator(_ s: String) -> String.Index? {
        for idx in s.indices {
            let c = s[idx]
            if c == "," || c == "|" { return idx }
        }
        return nil
    }

    private static func attribute(_ line: String, _ key: String) -> String? {
        let pattern = key + "=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: line, options: [], range: range), match.numberOfRanges > 1 else {
            return nil
        }
        return ns.substring(with: match.range(at: 1))
    }

    static func deriveName(_ url: String) -> String {
        var u = url
        if let q = u.firstIndex(of: "?") {
            u = String(u[..<q])
        }
        if let r = u.range(of: "://") {
            u = String(u[r.upperBound...])
        }
        if let slash = u.lastIndex(of: "/"), slash < u.index(before: u.endIndex) {
            return String(u[u.index(after: slash)...])
        }
        return u.isEmpty ? url : u
    }
}
