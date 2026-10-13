# MP4 内嵌 WebVTT 字幕切片契约

继续已授权 P02，接入本地/HTTP(S) MP4 的 `wvtt` 发现、选择和渲染，网络遵循 managed 策略；验证后本地提交。沿用当前字幕 owner、公共 API 和既有 WebVTT format，不修改原生桥接，不涉及并行长播放或弱网 ABR。整个 P02 继续开放。

## 发现、时间与载荷

- 在[既有 MP4 契约](2026-10-11-subtitle-mp4.md)的非分片 sample table 路径中增加 wvtt，与 tx3g 可在不同轨共存；身份仍为 `mp4:<Track ID>`，语言与名称仍取 mdhd/hdlr。同一轨的多个描述必须是同一 codec，wvtt 与 tx3g 描述混用显式拒绝。
- wvtt sample entry 使用同文件 data reference；必须有唯一 vttC，含有效 WEBVTT header 和可选 NOTE。可选 vlab 是不参与轨身份的 UTF8 标签，btrt 必须为12字节。拒绝 CSS/REGION、配置内 cue、加密和未知配置语义。
- 一个 sample 含1至64个 vttc，各自包含唯一必需 payl、可选 iden/sttg/ctim；唯一且空的 vtte 表示间隙。重复字段、越界长度、无效 UTF8/NUL、错误清屏组合拒绝。sample 内支持32/64位 box size，不接纳 size=0 或未知/vtta box。
- 时间取 stts/ctts 与既有简单 elst 映射，所有同 sample cue 共用 [start,end)。ctim 仅验证原始 cue 时间语法，不改写媒体时钟；相邻 sample 的同名 cue 分别保留，不以 iden 去重。零时长非空 cue 拒绝，编辑外内容不发布。
- 严格 UTF8 payl 归一化 CRLF/CR；直接创建内部 cue，不拼装 WebVTT 文件。payload 中空行和时间箭头不会注入新 cue。空 payl 不产生 cue。ID 禁止换行、控制字符与时间箭头。

## 渲染子集与会话

- 公共格式为既有 `webvtt`。复用外置 WebVTT 的纯文本、平衡 b/i/u、实体和水平 align/position 子集；sttg 与外置文本共用一个严格解析器。未知设置显式 subtitleUnsupported，无效值/重复设置为 subtitleMalformed。
- 不支持 line/size/vertical/region、CSS、voice/class/ruby、内联时间戳/karaoke。不是完整 WebVTT 排版引擎，也不宣称任意合法 wvtt 都能接纳。
- 复用现有字幕目录、选择/关闭、seek/偏移和第一帧门禁；失败原子保留旧目录/选择。换源、stop、dispose 或外置目录操作取消未完成扫描，迟到结果不能覆盖当前会话。

## 预算与网络

- 保留 MP4 既有轨道/样本/读取/原始字节预算。容器索引、wvtt配置/sample/内层cue以及stpp配置的box共享200000总上限，跨轨/样本描述/初始样本/后续分片累计；解析每个box前收费，恰好上限可用，下一项报limitExceeded。此前内层计数Minor在2026-10-12结构预算切片关闭。每 sample 最多64个 box；每 cue 或配置最多8个子box。每 payl/config ≤16384码元，iden/vlab/sttg ≤1024，ctim ≤32；解码前也检查字节上限。保留 packets 跨所有轨累计≤10000，样式 runs≤20000；目录归一化输入≤4MiB和同时活动≤64继续生效，计入 ID/settings 字节。
- 沿用未修改的 managed Range 读取器：单段206、稳定强ETag/总长/最终URI、后续If-Match，16KiB×128缓存、4096 HTTP尝试/64MiB响应体预算；connect/read超时、共享retry/redirect、跨源敏感凭据剥离和取消。没有完整200下载回退，也不扩大视频 managed 支持范围。
- 仍不支持 fMP4/moof/mvex、HLS/DASH、stpp、MOV旧text、位图/CEA、外部data reference、复杂编辑及受保护视频 overlay。

## 验证边界

新增手写 owned BMFF fixture，另以手算 vttc/payl 字节作解析对照；没有宣称 wvtt 独立生产器或物理设备互通性认证。验证实际文件、真实 loopback HTTP、公开 API 和 Flutter 布局几何，视频后端为 fake。原有独立 FFmpeg tx3g fixture 继续参加回归，但不作为 wvtt producer 证据。没有新增依赖或外部媒体；原生制品与配方重新核对 hash。无 native/device/HDR/DRM/PD-03/长播放/弱网 ABR 验收。

## 格式核对

仅用于核对格式语义，未复制实现：

- [Shaka MP4 WebVTT parser](https://shaka-project.github.io/shaka-player/docs/api/lib_text_mp4_vtt_parser.js.html)：vttc/payl/iden/sttg 与 sample 媒体时间。
- [W3C WebVTT](https://www.w3.org/TR/webvtt1/)：文本和 cue settings；实现只承诺上述有界子集。

## fMP4 extension (2026-10-11)

The earlier fragmented-MP4 exclusion is superseded for the bounded wvtt/stpp
subset in the [fMP4 contract](2026-10-11-subtitle-fmp4.md): initialization and
fragments in one complete file or stable HTTP resource, shared managed Range
loading and existing render subsets. Separate segment URLs, manifests/live
polling, fragmented tx3g and native/device acceptance remain outside scope.
