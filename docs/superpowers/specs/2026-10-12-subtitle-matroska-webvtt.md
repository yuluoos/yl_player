# Matroska 内嵌 WebVTT 字幕

继续 P02 字幕计划，在现有 `discoverEmbeddedSubtitles()` 中接入 WebVTT；本地文件和
HTTP(S) Matroska VOD 共用同一有界 EBML demux、TrackUID 身份、目录、选择和 overlay。
无公开 API、原生播放器、依赖或 managed 网络入口变更。

## 两种映射

- `S_TEXT/WEBVTT`：CodecPrivate 必须是可解析、没有 cue 的 WEBVTT 全局头。
  Block 只含 cue 正文，BlockAdditional ID 1 提供 settings、identifier、前置 NOTE。
  未写 BlockAddID 按默认 1；单个 BlockMore，MaxBlockAdditionID 可为 0/1。
  settings/identifier 可为空；最后 identifier 可省略末尾 LF；CRLF/CR 归一化。
- `D_WEBVTT/SUBTITLES`、`D_WEBVTT/CAPTIONS`：兼容 FFmpeg 在 Matroska 中使用的映射，
  Block 前两行依次为 identifier、settings，余下为正文；无非空 CodecPrivate 或 additions。
  只接受 TrackType 17 的字幕；不解释 descriptions/metadata，也不增加 webm DocType 支持。
- 两种映射均要求 BlockGroup 的显式正 BlockDuration；沿用 Cluster/Block 时间、TimestampScale、
  CodecDelay，不能用 DefaultDuration 猜测 WebVTT 结束点。容器时间始终为准。
- 字幕正文按既有 WebVTT 严格子集渲染：文本、受支持的行内样式、水平 align/position。
  CSS/REGION/vertical/line/size、内联时间戳、加密、压缩、lacing 和其他 additions 仍明确拒绝。
  全局头/NOTE 不能注入独立 cue；元数据 UTF8、NUL、重复元素、identifier 和 settings 验证。

## 限额、生命周期与网络

CodecPrivate ≤256KiB；每 Block/BlockAdditional ≤64KiB，identifier/settings ≤1024 码元，
正文 ≤16384 码元。所有原始头、正文和注释字节同时计入扫描 4MiB 上限和共享字幕目录
4MiB 上限，包括最终丢弃的 NOTE。沿用 10000 cue、64 并发 cue、read/结构和时间限制。
完整扫描、正文转换与目录预算验证完成后才原子发布；失败保留旧目录，不替视频决定存活。

HTTP(S) 复用已有 managed 单段206、强ETag/固定总长/最终URI、If-Match、重试/重定向/
凭据剥离、逐跳 connect/read 超时与窗口缓存。没有全量200回退、额外字幕URL或总deadline。
字幕扫描固定版本不保证 native 视频版本相同。选择、关闭、正负偏移、seek 和取消仍由
既有 session owner 管理；迟到网络响应不能重新发布目录或显示旧 cue。

## 验证与边界

合成标准 S_TEXT 样本覆盖字段/注释/错误/预算；真实 HTTP 验证 managed 行为；Flutter
fake 视频 backend 验证两映射同语言 main/forced 选择、粗体与25%位置、清屏和取消。
独立 host FFmpeg 8.0.1 自有 WebVTT→MKV 夹具覆盖 D_WEBVTT，按 ffprobe 的0.503–1.707s
验证。无 S_TEXT 独立生产器互通或实机播放声明，无 WebM/HLS/DASH/直播/跨Period支持扩展。
整个 P02、HDR/DRM/外接设备与 PD-03 仍开放；长播放和弱网 ABR 不在本项。

参考：[Matroska codec mapping §6.4/§7](https://datatracker.ietf.org/doc/html/draft-ietf-cellar-codec-17)
和 [WebM WebVTT mapping](https://www.webmproject.org/docs/container/#webvtt-guidelines)。

## WebM continuation (2026-10-12)

The previous WebM DocType exclusion is superseded by the [WebM contract](2026-10-12-subtitle-webm.md).
Automatic content detection and explicit webm now accept D_WEBVTT subtitle/caption
tracks; explicit Matroska/WebM hints are checked against DocType. Other constraints remain.
