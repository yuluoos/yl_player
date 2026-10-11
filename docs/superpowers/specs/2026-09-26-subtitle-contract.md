# P02 Task 1A：字幕 Dart 契约

本阶段承接已批准 P02 的来源、目录、active/off、偏移、命令确认和旧适配器拒绝要求。它是可选 Dart SPI 与公开值/命令的增量契约；native schema、实际下载/渲染、多音轨跨段身份实现仍属后续阶段。

## 值和身份

- `YlSubtitleFormat { srt, webvtt, ttml, ass, ssa, pgs, vobsub }` 表示格式身份，不保证某平台能解析/渲染。
- `YlExternalSubtitle(id, source, format, companionSource?, label?, language?, role?, contentId?)` 定义外挂字幕。资源复用 `YlMediaSource` 中的 File 与 HTTP(S) Network；媒体 format 必须 automatic，intent 为 automatic/onDemand，禁止 DRM、RTMP、content URI 和 live。HTTP 继承 `YlHttpRequest` 的凭据作用域与 `YlNetworkPolicy`，严格策略不能执行时必须拒绝。VobSub 主资源为 sub，companionSource 必须为 idx；其他格式不接受 companionSource。
- `YlSubtitleTrack(id, format, isExternal=false, label?, language?, role?, contentId?)` 是公布的目录项。id 是会话内唯一且稳定的 opaque 标识，不能由数组下标或单一语言生成。同语言不同 role/codec/content 不自动视为相同轨道；重复 id 无效。内容身份未知时保留 null，不能根据缺失语言猜测身份。
- `YlSubtitleState(tracks=[], selectedTrackId=null, offset=Duration.zero)` 为不可修改的快照。null 表示关闭，无隐含自动选字幕。选中 id 必须存在；offset 正值延后显示，负值提前。
- `YlPlayerState.subtitles` 默认空/关闭/零偏移，copyWith/equality/hash 包含字幕状态。idle 状态不可携带字幕目录/选择/偏移。

标识/label/contentId 最多 1024 UTF-16 code units，language/role 最多128；非空字段禁止 C0/DEL 控制字符。目录最多128项，单次外挂集合最多32项且 id 唯一；源 URI/path 最多8192 code units。偏移要求整数毫秒、±7天。以上预算是合约输入边界，不是媒体或进程内存预算。toString 与 ArgumentError 不回显敏感值。

## 命令与迁移

公开会话方法：

```dart
Future<void> replaceExternalSubtitles(List<YlExternalSubtitle> subtitles);
Future<void> selectSubtitleTrack(String? trackId);
Future<void> setSubtitleOffset(Duration offset);
```

可选 `YlSubtitlePlatformPlayer` 提供同名方法，首参为 `YlPlaybackSessionId sessionId`。`YlPlayerOperation` 末尾追加 `externalSubtitles`、`subtitleTrackSelection`、`subtitleOffset`，旧 operation ordinal、YlTrackKind 的 audio/video 0/1 和两端 Pigeon enum 均保持不变。只有接口与对应 capability 同时存在才派发；否则以 command scope、unsupported category、policy.unsupported、retryable=false 拒绝，不调用 native。

命令派发前检查会话、校验参数并复制外挂列表；Future 成功表示适配器完成该命令对应的提交，不代表第一帧字幕呈现。完成或失败回包后再次检查会话；已被替换/Stop 的旧会话报 session.stale，Dispose 报 player.disposed。公共 wrapper 不乐观修改 state；仅接受平台递增 revision 的权威快照。适配器负责同会话重叠命令的代际隔离、真实资源取消和按序提交，不能在新会话发布旧目录或旧 cue。

replace 是原子替换全部外挂项，保留内嵌项；空集合清除外挂。失败保持旧集合和选择。选中外挂被移除则关闭字幕；保留相同 id 但内容替换时必须清掉旧 cue 再发布新内容。新 Load 初始关闭且 offset=0；同会话 seek 保留选择/偏移，清理旧 cue 后按新媒体时间计算。目录变化使选中字幕消失时关闭并发布 null，不按语言自动另选；此规则不改动视频 PD-01 或音轨选择规则。

支持声明必须意味着完整履行相应命令，不可因为有 parser 而提前声明支持。当前 Android/Apple 未实现此 SPI，所有新命令均明确 unsupported；无 Pigeon schema 变动或 native 生成物更新。后续 native 接入必须协商协议并验证未知消息/版本拒绝，不允许仅强转新 enum ordinal。

## 故障与验证

本阶段仅覆盖参数/不支持/生命周期错误，复用既有 YlFailure。解析/字体/位图错误到公开失败的映射、是否终止视频继续受 PD-03 约束；不设置默认恢复策略。状态不存原始字幕 payload，也不把 parser raw markup 当渲染文本。

验证：来源/预算/脱敏/值语义、目录重复/同语言不同role、选择失效、状态集成、enum稳定、旧适配器拒绝、capability与接口双门禁、参数复制、ACK等待、迟到成功/失败与Stop/Dispose，以及现有两平台 Dart桥接/公共API回归。通过不代表实际多音轨切换、字幕合成、网络取消或 HDR/DRM 验收。
