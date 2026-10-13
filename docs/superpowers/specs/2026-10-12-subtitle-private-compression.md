# Matroska CodecPrivate 压缩恢复

> 2026-10-13：以下首版单层/链式拒绝边界已由[多层压缩契约](2026-10-13-subtitle-compression-chain.md)
> 扩展为最多4层、有序且独立筛选Block/Private作用域；Next/加密/WebM限制保留。

延续既有 P02 与单层字幕压缩切片，支持 Scope2（仅CodecPrivate）及 Scope3（Block与
CodecPrivate）。保持 Order0/Type0、zlib/header stripping 算法和严格有界恢复器。
Scope1原行为保持；Scope0、Next bit、未知位、链式、加密与WebM压缩仍拒绝。

在UTF8及codec-specific私有头验证前恢复CodecPrivate字节。Scope2不修改Block，Scope3
使用同一算法/settings分别独立恢复私有头与每个Block。BlockAdditional不受影响。
声明包含Private scope时必须有CodecPrivate元素，空元素允许经header stripping恢复；
无私有头的codec仍按其原契约要求恢复内容为空。不存在时不合成旁路资源。

原始和恢复后的私有头各≤256KiB，恢复前传递全容器4MiB剩余字节预算；原始压缩头、
settings、恢复内容共同计量。原始压缩头字节加入已有compressionBytes，WebVTT原始
文档额度使用恢复后的头长度，确保大小不会漏算也不会重复计压缩头。ASS/SSA/VobSub
复用各自既有头解析；目录保留预算也覆盖空轨和后续外挂替换/rediscovery。
Block/恢复的单包、RGBA64MiB及managed扫描预算维持原约束，失败原子保留旧目录。

验证包含文件RED/GREEN、私有头UTF8/codec语义、两算法与Scope2/3组合、恢复后上限/
跨轨/外挂保留预算、真实managedHTTP、公开会话渲染/取消、独立Python压缩头金标。
最后四包回归、静态分析、一次独立复审、冻结指纹和限定范围commit；同步create/discover
API注释。长播放/弱网ABR排除，无新增依赖或原生变更。

依据：[Matroska ContentEncodingScope](https://www.matroska.org/technical/elements.html)。
这不扩展高级字幕效果、链式/Next压缩、WebM、native/device/HDR/DRM、直播清单/Period/
PD03或整个P02；金标不等于独立Matroska muxer与设备认证。
