# MP4 内嵌字幕扩展语言标签（2026-10-13）

在已支持的 MP4 品牌和 tx3g/wvtt/stpp 轨道内读取 mdia 的可选单个 elng；
普通 MP4、单资源 fMP4 和混合初始样本/分片均通过同一轨道解析路径。
结构为 version=0、flags=0 的 FullBox，随后为 ASCII 语言标签和一个末尾 NUL。
有效标签覆盖原有 mdhd 三字母语言，保留大小写；缺失时沿用 mdhd。
轨道身份仍来自 tkhd.track_ID，语言变化不自动切换或合并轨道。

标签执行 RFC 5646 well-formed 语法检查：语言/extlang/script/region/variant、
extension、private-use 和固定 grandfathered 标签；重复 variant 和扩展 singleton
按大小写不敏感拒绝。这里只检查语法，不查 IANA 注册表、不验证已注册组合、不做
canonicalization、语言协商或自动选轨。128 个 ASCII 字符是现有公开元数据预算，
不是 BCP 47 格式上限；超过 133 字节的 elng payload 在请求正文前报 limitExceeded。
重复 box、空标签、缺失/多余 NUL、非 ASCII 或语法错误报 malformed；
未知 version/flags 报 unsupported。elng 参与既有共享 box/read 预算。

Ruling：保留既有 mdhd 验证；即使 elng 有效，损坏 mdhd 也不能绕过容器准入。
对非法 elng 采用项目严格、原子拒绝策略，而非容错忽略。代价是部分可挽救文件仍会
拒绝字幕发现，播放状态和既有目录/选择保持不变。此策略不声称完整 QuickTime 容错实现。

API discoverEmbeddedSubtitles 注释补齐上述语义。网络沿用 managed Range、强 ETag、
请求凭据和取消/重试路径，不引入另一个 HTTP 客户端。解析/实际文件/本机 HTTP/
公开 widget 验证覆盖语言、选轨、字幕绘制、关闭、偏移和失败恢复。fixture 为项目构造，
不声称独立 muxer 或 native/device/HDR/DRM/外接验收。不扩大 MOV 容器准入或跨 Period
语义，整个 P02 仍开放；长播放、弱网 ABR 和 P05 不属于本项。

依据：[Apple elng 字段](https://developer.apple.com/documentation/quicktime-file-format/extended_language_tag_atom/language_tag_string)、
[Apple media/elng 位置](https://developer.apple.com/documentation/quicktime-file-format/media_atom/extended_language_tag_atom)、
[Apple atom FullBox 规则](https://developer.apple.com/documentation/quicktime-file-format/atoms)、
[RFC 5646 §2.1/§2.2.9](https://www.rfc-editor.org/rfc/rfc5646.html)。
