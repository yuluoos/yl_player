# Matroska 压缩字幕

延续P02独立字幕切片，接入现有发现/选择/渲染链路的 ContentCompression：单一
ContentEncoding、Order0、Scope1（Block）、Type0，支持Algo0 zlib与Algo3 header stripping。
字段省略时采用标准默认值；拒绝多层、CodecPrivate/Next scope、加密、未知算法、非空zlib
settings。header stripping必须有settings（可为空）。WebM的ContentEncodings暂不扩展。
轨道的CodecPrivate本身仍按原有codec规则处理。

解压后的Block送入既有UTF8/ASS/SSA/WebVTT/PGS/VobSub路径；BlockAdditional不受Block
压缩影响，时间、TrackUID、选择、像素合成与managed请求/取消/原子发布沿用既有实现。
公开create/discover API注释标明支持范围。没有新增依赖、原生桥或网络入口。

## 有界恢复与严格失败

每块存储压缩输入≤256KiB；恢复后文本≤64KiB、PGS≤256KiB、VobSub≤65535字节。
全容器4MiB预算同时计压缩输入、settings、恢复内容、原CodecPrivate/附加内容。
运行时保留压缩输入/settings额外字节额度，后续外挂替换与rediscovery不能丢失这笔预算。
RGBA目录仍64MiB，字幕/cue/轨道和扫描请求预算保持既有值。

zlib使用内部无外部资源的RFC1950/1951解码器，支持stored/fixed/dynamic Huffman、重叠
back-reference、最大32KiB窗口。仅接受单一完整流、合法Huffman/距离、Adler32，拒绝
gzip、preset dictionary、截断、尾随或拼接流。每次输出/复制先检查剩余额度；输出缓冲按需
增长，上限是剩余预算和单包上限较小者，每流最多10000个DEFLATE块。不可先无限解压再截断。
此限制只描述字幕解析预算，不是整个进程/GPU RSS保证。

## 验证

真实文件RED后GREEN；原有压缩拒绝测试仍覆盖非法空ContentEncodings。SDK encoder多等级/
策略和独立Python zlib金标交叉验证严格解码；包含损坏结构、超大压缩比、确切边界、各已支持
codec恢复、真实HTTP managed策略、Flutter选择/清屏/取消、跨目录输入预算。最后四包回归、
静态分析、一次独立复审、冻结源与证据并限定范围commit。长播放/弱网ABR排除。

依据：[Matroska elements](https://www.matroska.org/technical/elements.html)、
[RFC1950](https://www.rfc-editor.org/rfc/rfc1950)、[RFC1951](https://www.rfc-editor.org/rfc/rfc1951)。
通用压缩库、任意压缩层、WebM压缩、native/device/HDR/DRM、直播清单及整个P02仍开放。


## 2026-10-12 CodecPrivate 压缩扩展

此前仅Block scope的限制扩展为Scope1/2/3：单层zlib/header stripping可以作用于CodecPrivate
或同时作用于Block和CodecPrivate。私有头先恢复后UTF8/codec验证，原始与恢复字节共同
计量并保留到目录；旧“私有头压缩不支持”由
[私有头压缩契约](2026-10-12-subtitle-private-compression.md)限定替代。
Next/链式/加密/WebM和其他未实现范围保持不变。
