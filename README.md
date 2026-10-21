# AuroraPlayer（极光播放器）

iOS 原生播放器，支持 HLS 与 **DASH + ClearKey(CENC)**，可从在线/本地 M3U 列表导入频道。
产物为未签名 IPA，通过 GitHub Actions（macOS）云端编译。

## 支持的列表标签

```m3u
#EXTINF:-1 group-title="测试",频道名
#KODIPROP:inputstream.adaptive.manifest_type=mpd
#KODIPROP:inputstream.adaptive.license_type=clearkey
#KODIPROP:inputstream.adaptive.license_key=KID:KEY
#EXTVLCOPT:http-user-agent=Mozilla/5.0 ...
#EXTVLCOPT:http-referrer=https://example.com/
https://example.com/live/stream.mpd
```

- `KID` / `KEY` 支持 32 位十六进制，可带 `-` 分隔；多个 key 用 `;` 分隔。
- 请求头会同时用于 MPD、分片下载。
- 也兼容 `#KODIPROP:inputstream.adaptive.stream_headers=User-Agent=...&Referer=...`。

## 播放原理（DASH/ClearKey）

AVPlayer 本身不支持 DASH 与 CENC，因此走自研管线：

1. 解析 MPD（SegmentTemplate / SegmentTimeline / SegmentList，静态与直播）
2. 下载初始化分片，读取 `tenc`（KID、IV 长度、cbcs pattern）
3. 按需下载媒体分片，用 CommonCrypto 做 AES-CTR / AES-CBC pattern 解密
4. 去掉 `sinf`/`senc`/`saiz`/`saio` 等加密信令（并修正 `trun.data_offset`）
5. 由 App 内回环 HTTP 服务输出 HLS（master + 分轨 playlist，支持 Range）
6. 交给 AVPlayer 播放

解密实现已用 Bento4 生成的真实加密样本做逐字节比对（400 个样本完全一致），
并在单测中固化为回归测试。

## 测试

```bash
xcodegen generate --spec project.yml
xcodebuild test -project AuroraPlayer.xcodeproj -scheme AuroraPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:AuroraPlayerTests
```

CI 每次构建都会先跑单测（M3U 标签解析、MPD/分片展开、ClearKey 解密与 init 重写）。

## 内置演示频道

`AuroraPlayer/Resources/demo.m3u` 最后一条是 13 秒的 ClearKey DASH 测试流，
文件托管在 `demo-dash/`（KID `feedf00d-eede-adbe-eff0-baadf00dd00d`，
KEY `00112233445566778899aabbccddeeff`），可用于端到端验证。

## 已知限制

- 只支持 ClearKey，不支持 Widevine / PlayReady / FairPlay。
- 仅处理第一个 Period；不支持 Period 切换。
- 不支持 `SegmentBase`（单文件 + sidx）形式的 DASH。
- 多 KID 轮换、`keyrotation` 未实现（只按初始化分片的 KID 取 key）。
- 直播需要 `availabilityStartTime`，或使用 SegmentTimeline；否则无法推算可用分片。
- 未在真机联调：解密与容器改写已验证，AVPlayer 对本地 fMP4 HLS 的兼容性待实测。

## 构建产物

未签名 IPA 由 `.github/workflows/build-ipa.yml` 生成，artifact 名
`AuroraPlayer-unsigned-ipa`。安装需自行签名（AltStore / Sideloadly / 开发者证书）。
