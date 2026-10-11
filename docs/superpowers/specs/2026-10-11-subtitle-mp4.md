# MP4 内嵌字幕切片契约

继续已授权 P02，用户指定本地/网络 MP4 发现、选择、渲染与 managed 网络策略，验证后本地提交，排除并行长播放/弱网 ABR。本项沿用现有 Dart 字幕 owner 和 `discoverEmbeddedSubtitles()`，不扩展原生桥接或播放器支持路线；不把整个 P02 标为完成。

## 接纳与身份

- 非分片 ISO BMFF MP4 的 `tx3g`（mov_text）样本，文件或 HTTP(S) on-demand/automatic；显式 `mp4` 或 automatic 首 box 为 ftyp（MKV 仍按 EBML 识别）。接受 isom/iso2..6/mp41/mp42/M4V/所列3gp/3g2 compatible brands，拒绝只声明 QuickTime 的容器。自动识别不依赖 URL 后缀或 Content-Type。
- 每个 `trak` 的非零32位 Track ID 必须唯一，包括音视频轨；字幕 ID 为 `mp4:<decimal ID>`。读 mdhd 的 packed ISO639-2 language 和 hdlr UTF8 label。`text/sbtl/subt/clcp` handler 中只有 tx3g 支持；不支持的字幕 codec 整体拒绝，不静默丢弃。视频和音频不解析样本数据。
- tkhd enabled 是文件默认呈现标志，不是可发现性门禁；未启用字幕也可列出供用户选择。同语言轨道不合并。不会自动选中 default/forced，重新发现按身份保留选择，消失后关闭。
- 公共 `YlSubtitleTrack.format` 使用既有 `srt` 作为标准文本 cue 归一化形式，**并非声称 MP4 载荷编码为 SRT**；无需添加公开 enum 或改变 Pigeon。mp4 ID 区分来源，实际 tx3g 样式通过内部纯文本 runs 传递，绝不再次解释为 HTML/SRT/ASS。

## 容器与时间

- 有界 random-access box walker 支持32位和64位长度、顶层末尾 size=0；严格父边界/重复必需 box/表长度。moov 前置或尾置都可；mdat/free 的内容跳读，所引用样本必须全部落在同文件的 mdat 内。
- mvhd/mdhd/tkhd v0/v1 字段、stsd、多描述按 stsc 选择；stco/co64、stsz 常量/数组和 stz2 4/8/16位；stts 展开数量匹配样本，ctts v0/v1 支持有符号偏移，stss 索引验证。chunk 数量、描述下标、映射和样本数量匹配；同轨 chunks 不得重叠。
- elst v0/v1 接受单个 rate=1 播放编辑，或一个空白编辑后接单个播放编辑；裁切媒体起点/编辑终点，支持首部空白。重复播放、dwell/变速编辑拒绝。先组合整数时间比例再换算微秒，避免分别舍入引入误差；保留 [start,end) 媒体时段。
- 空文本是间隙/清屏，不生成 cue；终端空文本可零时长，非空文本必须正时长。超出编辑的内容不发布；样本仍校验、计入预算。轨道可为空。

## tx3g 解码与渲染子集

- 严格 UTF8，或带 BOM 的 UTF16 BE/LE（拒绝孤立 surrogate、奇数字节与NUL）。文本长度字段为字节长度；style 位置按 Unicode scalar 数，支持相邻/分段、不重叠且不越界。
- 默认 style 与 styl override 支持粗体、斜体、下划线、RGBA、font ID/字体名、字号。最多64个字体名，无任何字体下载/外部资源；由 Flutter 本地字体系统回退。字号按 Flutter logical pixel 呈现，字体度量和 native/QuickTime 不要求像素一致。
- 接受 left/center/right 水平对齐、bottom 垂直位置、零默认文本框；使用已有可见视频 aperture 与普通字幕布局。背景色作为文本 run 的底色绘制；不宣称完整 tx3g 文本框填充或轨道矩阵几何。非零默认 box、其他垂直位置、tbox、fill-region/滚动/karaoke/highlight/链接等效果拒绝。
- flags=0 普通字幕；`0xC0000000`（some+all forced）标记整轨 forced。只有 some-forced 或只有 all-forced、per-sample frcd 本轮不接纳，不把部分强制误报为整轨。
- 嵌入文字中的 `<b>`、`{\\...}`、时间箭头等按字面绘制，不能注入额外 cue。关闭、切轨、seek、偏移、换源的清屏和第一帧门禁复用既有 owner。

## 预算、请求与错误

- 每次解析≤200000个box、根≤4096、每个容器≤256子box；≤128总轨、≤32字幕轨、≤32样本描述、≤20000样本（包括空样本）与 chunks/time rows。
- 单次读取≤256KiB、总元数据/样本读取≤64MiB；字幕样本原始字节累计≤4MiB。单文本≤16384码元、单sample≤1024样式段；保留样式runs≤20000。时间线≤7天。既有目录总计4MiB归一化输入、10000 cue、20000 runs 和64同时活动 cue 继续生效。
- 文件使用已有串行随机访问/描述符释放/30秒协作式期限。网络完全复用 [网络 Matroska 读取器](2026-10-11-subtitle-network-matroska.md)：16KiB窗口/128项LRU、4096实际HTTP尝试/64MiB body进度（含重试），单段206、强ETag/固定总长/最终URI、后续If-Match，禁止完整200回退。
- managed 执行逐跳 connect/空闲 read 超时、共享 retry/redirect 额度、Retry-After、跨源敏感头剥离、TLS验证/拒绝HTTPS降级，不额外增加总期限；platformDefault 沿用30秒总期与不重试。MP4字幕可发现并不扩大原生视频的 managed 支持矩阵。
- 换源/Stop/Dispose/目录操作取消扫描并拒绝迟到发布。失败原子保留旧目录/选择，映射已有脱敏 subtitleMalformed/subtitleUnsupported/subtitleTooLarge/networkFailed，不暴露URL/头/媒体正文。不改变 PD-03 或视频失败状态。

## 范围与成本

fragmented MP4/mvex/moof、HLS/DASH、MOV旧text、wvtt/stpp、位图/CEA字幕、加密entry/外部dref、复杂编辑和高级tx3g效果均未实现。接纳子集严格，不代表任意合法MP4字幕；资源较大或复杂的轨道可能因明确上限拒绝。发现扫描固定版本仅涵盖字幕请求，不能证明 native 视频请求版本相同。内存上限是每扫描/目录预算，不是进程RSS承诺。

验收使用 owned byte fixture、host FFmpeg 独立封装的 owned MP4/ffprobe、真实文件/loopbackHTTP以及 Flutter 公共API/渲染（fake视频后端）；不进行native构建、设备/HDR/受保护播放、长播放或弱网ABR验证。原生制品/license/依赖核对沿用并重新hash，未新增运行时依赖或拷贝外部媒体。

## 参考

只作格式核对，未复制实现代码：

- [Apple Subtitle sample description](https://developer.apple.com/documentation/quicktime-file-format/subtitle_sample_description)
- [Apple tx3g display flags](https://developer.apple.com/documentation/quicktime-file-format/subtitle_sample_description/display_flags)
- [Apple subtitle placement](https://developer.apple.com/documentation/quicktime-file-format/subtitle_track_header_size_and_placement)
- [FFmpeg n8.0 movtext decoder](https://github.com/FFmpeg/FFmpeg/blob/n8.0/libavcodec/movtextdec.c)

## WebVTT extension (2026-10-11)

The historical wvtt exclusion above is superseded by the
[MP4 WebVTT contract](2026-10-11-subtitle-mp4-webvtt.md) for the bounded
non-fragmented wvtt subset. Those tracks use the existing public `webvtt` format;
tx3g normalization remains unchanged. Retained packets now enforce the existing
10000-cue catalog ceiling across tracks during parsing, before catalog publication.

## MP4 TTML extension (2026-10-11)

The earlier stpp/MP4-TTML exclusion is superseded for the non-fragmented bounded
subset in the [MP4 TTML contract](2026-10-11-subtitle-mp4-ttml.md). Existing public
`ttml`, styled runs/regions and managed Range loading are reused. Composition
time, sample clipping and simple edits are explicit; advanced TTML remains rejected.

## fMP4 extension (2026-10-11)

The earlier fragmented-MP4 exclusion is superseded for the bounded wvtt/stpp
subset in the [fMP4 contract](2026-10-11-subtitle-fmp4.md): initialization and
fragments in one complete file or stable HTTP resource, shared managed Range
loading and existing render subsets. Separate segment URLs, manifests/live
polling, fragmented tx3g and native/device acceptance remain outside scope.
