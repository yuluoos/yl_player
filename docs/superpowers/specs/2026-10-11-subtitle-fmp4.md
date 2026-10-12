# 分片 MP4 内嵌 tx3g / WebVTT / TTML 契约

继续既有 P02 字幕切片：当前已提交的本地文件或 HTTP(S) 来源，显式 `discoverEmbeddedSubtitles()` 后按 `mp4:<Track ID>` 选择。复用公开归一化 `srt`（tx3g）/ `webvtt` / `ttml` 格式和现有字幕 owner/Flutter overlay，不新增 API、网络入口、原生桥或依赖。长播放和弱网 ABR 由另一会话负责。

## 单资源范围

- 一个完整资源包含 `ftyp`、单个 `moov/mvex` 初始化信息和其后的 `moof/mdat`；字幕初始化样本表可以为空或包含初始样本，随后与分片接续。初始化信息本身可返回空轨道。tx3g/wvtt/stpp 可以分轨共存；每轨样本描述必须是同一 codec。
- 读取 `trex` 默认值，`tfhd` 覆盖 track/sample description、duration、size、flags，`trun` 再覆盖逐样本值。显式零值不回退到默认值。支持多个 run、多个 traf、32/64 位 box 长度。
- 字节基址支持显式 `base_data_offset`、`default-base-is-moof` 和首个 traf 的隐式 moof 基址。`data_offset` 是有符号32位，允许同资源中位于 moof 前的 mdat。后续 run 缺少 offset 时接着上一个 run；不根据被跳过的音视频负载推算后续 traf 基址，后续字幕 traf 须显式指定基址或 default-base-is-moof。
- 样本字节必须完整落在顶层 mdat 的 payload 中；字幕样本之间不得重叠。音视频 payload 不解码、不复制；有界窗口网络缓存可能读到相邻字节。
- 每个字幕 traf 必须有 `tfdt` v0/v1，`trun` v0/v1 支持 unsigned/signed composition offset。decode 时间不倒退/重叠，可留空隙；mfhd 序号严格递增，可不连续。duration-is-empty 不得携带样本。未知/加密/子样本布局、缺 tfdt 明确拒绝。
- 不读取独立 `.m4s` 与另一个初始化 URL；不解析 HLS/DASH 清单，不追踪直播增长或跨 Period 轨道，也不自动加载 segment URL。不是所有合法 fMP4 的兼容性承诺。

## 时间、显示与预算

tx3g 和 WebVTT 使用 `(tfdt + preceding durations + composition offset)` 的 sample 区间。TTML 文档时间沿用 ISO14496-30:2018/Amd1:2022 的 composition 时间，不重复加 sample 起点；先裁切 sample 再做简单 rate1 edit。三种格式均支持既有单一播放编辑/可选前导空白；分片模式的播放 edit duration=0 表示后续媒体，仍受7天上限限制。计算采用整数比例至微秒，区间为 `[start,end)`。

沿用 [wvtt 子集](2026-10-11-subtitle-mp4-webvtt.md) 和 [stpp 子集](2026-10-11-subtitle-mp4-ttml.md)：基本样式、水平 WebVTT position/align、TTML 百分比 region。每个 XML sample 的样式和 region 身份独立。高级 CSS/TTML、字体或图形资源等未扩大接纳范围。

跨分片共享 MP4 的20000样本、10000发布cue、20000保留run、4MiB原始字幕payload、64MiB解析读取、200000结构box计数，以及单次读取256KiB、每容器256子box、顶层4096box、32字幕轨/128总轨和7天时间界限。TTML空/编辑外文档也计入目录原始输入预算。已有 WebVTT sample 内局部box由payload/local-child限制约束，未追加到结构box计数（前一切片已记录 Minor）。这些是扫描/目录预算，不是进程 RSS 保证。

## managed 网络和原子生命周期

使用现有 managed Range reader：单段206、稳定强ETag/总长/最终URI、后续 If-Match；16KiB窗口×128缓存、4096次HTTP尝试、64MiB响应体。connect/read超时、重试/重定向总账和跨源敏感头剥离均复用原实现。没有200全量回退、schema/字体/XML引用请求，未新增扫描总deadline。

完整扫描成功后一次替换内嵌目录；任意后续分片损坏/版本变化/网络失败保留旧目录、选择和视频状态。换源/stop/dispose/替换外置字幕取消扫描，不发布迟到结果。切轨/off/seek/正负偏移及首帧门禁由原owner管理。

## 验证边界和参考

Owned手写BMFF/XML、真实临时文件和loopbackHTTP验证解析和managed请求；Flutter测试验证实际文字、样式、region矩形、切轨/seek/off/offset与迟到取消，视频backend为fake。未声称第三方生产器正向互通、native/设备/HDR/DRM/PD-03验收，整个P02仍开放。

- [W3C ISO BMFF byte stream format](https://www.w3.org/TR/mse-byte-stream-format-isobmff/)：初始化/分片结构、tfdt、moof相对寻址和零duration编辑语义；本项是完整文件读取，不宣称完整MSE实现。
- [Shaka MP4 WebVTT parser](https://shaka-project.github.io/shaka-player/docs/api/lib_text_mp4_vtt_parser.js.html)：分片sample时间及vttc/vtte对照，未复制代码。
- [ISO14496-30:2018/Amd1:2022](https://www.standards.iteh.ai/catalog/standards/iso/c559486e-2191-4975-ad44-9f061b600281/iso-iec-14496-30-2018-amd-1-2022)：TTML composition时间及sample裁切（此前stpp切片采用）。

## tx3g extension (2026-10-11)

The former fragmented-tx3g exclusion is superseded by the [tx3g continuation](2026-10-11-subtitle-fmp4-tx3g.md).
Existing literal styled text and normalized `srt` catalog entries now share this
fragment reader. The original WebVTT/TTML positive fixtures remain owned builders;
tx3g additionally has an independently muxed FFmpeg positive fixture.

## Hybrid MP4 extension (2026-10-12)

The earlier empty-initial-subtitle-table requirement is superseded by the
[hybrid MP4 contract](2026-10-12-subtitle-hybrid-mp4.md). Initial stbl samples and
later moof samples now share track state, decode continuity, subtitle extents
and budgets in one complete resource; existing codecs, managed loading and
rendering subsets remain in force.
