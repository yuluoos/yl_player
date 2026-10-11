# P02 内部文本字幕解析契约

本切片承接已批准 P02 的有界解析和媒体时钟选择。它是 `yl_player/lib/src/subtitles/` 内部基础，不是完整字幕公开 API，也不标记 CAP-SUB 通过。

## 输入、输出和时间

`SubtitleDocument.parse(List<int>, format: SubtitleFormat, limits: SubtitleLimits)` 同步消费已经取得的 UTF-8 字节；没有 I/O、网络、字体或外部引用解析。格式必须明确指定为 `srt` 或 `webvtt`。成功返回不可修改的 cue 列表；任何损坏或超限使整个文档失败，不返回成功前缀。

`SubtitleCue` 保存文件序号、可选原始标识、起止 `Duration`、原始 payload、WebVTT position 百分比/锚点和 align。标识可重复，不能当跨轨道/跨 Period 身份。payload 保留换行与标签，不等于纯文本或已验证的样式树；后续渲染器必须独立处理，不能直接作为 HTML 执行。默认 align=center、position 未指定、positionAlignment=auto。

`cuesAt(position, offset: Duration.zero, enabled: true)` 用媒体位置计算 `[start, end)`。正偏移延后显示；负偏移提前。重叠 cue 按原文件顺序返回。查询不保留上次状态，seek 回起点不会残留旧 cue；enabled=false 返回空列表。它不安排定时器，暂停/倍速应由上层传入的媒体位置体现。

媒体位置为负时返回空；offset 限于 ±7 天，否则 ArgumentError。大于 14 天的位置返回空，避免极端 Duration 减法溢出。内部平衡区间索引按子树最大结束时间裁剪，递归深度随 cue 数对数增长，返回数受重叠预算约束。

## 当前语法边界

SRT：可选数字序号，`HH:MM:SS,mmm`，小时至少两位，允许 cue 未排序和重复标识。WebVTT：BOM 可选，WEBVTT 签名与可选注释，空行分隔，NOTE、可选 cue 标识、`MM:SS.mmm` / `HH:MM:SS.mmm`、非递减开始时间、position/align。两者接受 LF/CRLF/CR，分钟秒为 0–59、结束严格晚于开始；严格要求时间箭头两侧空白。空 SRT 或仅有效 WebVTT 签名可产生空文档。

WebVTT STYLE/REGION、额外 header（包括 HLS X-TIMESTAMP-MAP）以及 position/align 以外的 setting 暂时显式 unsupported，不能忽略时间映射而移位播放。未知/重复/损坏已支持 setting、无效 UTF-8/NUL、缺 payload 和缺块分隔显式 malformed。本实现是严格受限入口，不声称实现浏览器式容错解析。原始标记文本仅保留，尚未完成 WebVTT cue text 的语义解析或效果验收。

语法参照 [W3C WebVTT 2026-05-20 草案](https://www.w3.org/TR/2026/CRD-webvtt1-20260520/) 的时间戳和 cue settings 定义；受限解析器的拒绝策略由本契约明确规定。

## 独立资源预算和安全错误

| 项目 | 默认及硬上限 | 检查位置 |
|---|---:|---|
| 输入 | 4 MiB | UTF-8 解码前 |
| cue | 10,000 | cue 分配前 |
| 单 cue payload | 16,384 UTF-16 code units | join 前 |
| 同时有效 cue | 64 | 时间事件扫描，等时先结束后开始 |
| 文本行 | 最多 50,000（换行数少于 50,000） | split 前 |
| 标识/时间行 | 各 1,024 code units | 解析/保留前 |
| 时间戳 | 最多 7 天；小时最多 3 位 | 整数乘法前 |

前四项可调低，不可超过硬上限；配置错误为安全 ArgumentError。输入预算约束已经分配的字节，不包含下载过程；未来网络入口须流式限额并支持取消，不能先无限下载后调用 parser。解析中副本、行对象和索引均受上述边界限制，但这些数值不是进程 RSS 上限，也不属于 `buffer.bounded` 媒体账本。

`SubtitleParseException.reason` 仅为 malformed / unsupported / limitExceeded；异常和 cue 的 toString 不包含输入文本、标识、URL 或底层解码异常。后续宿主层负责映射公开失败及诊断关联；本层不发布 YlFailure，不决定视频是否继续，PD-03 保持未决。

## 后续接入边界

现有 `YlTrackKind`、AppleTrackKind、AndroidTrackKind 都只有 audio/video（ordinal 0/1）。`YlMediaTrack` 有 language/codec，但无 role/内容身份；`YlPlayerState` 和 Pigeon 只传音视频目录。Apple DASH 仍只有单 audio rendition。此次不更改这些 ordinal、目录、命令或 public exports。

P02 Task 1 仍需冻结跨段音轨身份、字幕来源及 managed 请求、目录、选择/关闭/偏移命令、ACK/取消、旧适配器明确拒绝和协议迁移。Task 2 仍需 TTML、网络与会话生命周期、实际画面合成、三端媒体同步。ASS/SSA、PGS/VobSub、HDR/保护输出效果按原计划继续；本契约不提前决定其行为。
