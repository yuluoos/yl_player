# Matroska 字幕多层压缩契约（2026-10-13）

延续P02内嵌字幕链路，支持每轨1至4个ContentEncoding，只包含zlib和header stripping。
ContentEncodingOrder取无符号整数（既有安全数值范围），省略默认0，必须唯一；无需连续，
物理元素顺序不决定解码顺序。按Order降序恢复，Block/CodecPrivate分别筛选Scope位1/2，
Scope3同时适用；每块/私有头独立恢复，不依赖前块。任一Private作用域仍要求CodecPrivate。

依据：[Matroska元素规范](https://www.matroska.org/technical/elements.html)规定最高Order先解码、
各Order唯一；Scope位1/2/4代表Block/Private/Next。这里最多4层是项目资源策略，不是格式上限。
Next、加密、未知位/算法、非空zlib字典配置和WebM压缩继续明确拒绝。
重复Order报malformed，超过4层报limitExceeded；不支持的编码仍报unsupported。

原始压缩块/私有头、每层settings和每层输出共同消耗同一4MiB解析额度。原始压缩输入和
每个中间结果≤256KiB，最终块恢复受既有codec上限约束（文本64KiB且≤16384码元、
PGS256KiB、VobSub65535字节），最终Private≤256KiB。每一层恢复前传入剩余额度，
严格zlib校验、取消检查不变。中间压缩流可能比最终明文大，不误用最终codec上限限制中间层。

目录compressionBytes保留settings、原始压缩输入及所有中间结果长度，最终恢复内容由
既有文本/图形codec记账，不能重复或漏算。Private/Block作用域互相过滤；空轨、再次发现、
外挂先加载/后加载都保留目录总额。不改变全进程RSS、GPU或硬期限保证。

发现/选择/关闭/偏移和managed HTTP Range/ETag/凭据过滤/重试/取消仍走原链路。
失败不替换已提交目录/选择；PD03不在本项裁定。兼容已有UTF8、ASS/SSA、WebVTT、
PGS、VobSub解码子集，未扩展高级效果、字体获取、native/device/HDR/DRM/外接、
独立分段/清单/直播/跨Period或整个P02完成度。长播放/弱网ABR工作不变。

验证包含两算法×三作用域×七codec、乱序/稀疏/四层/重复Order、混合scope、逐层损坏和
预算、实际文件/managed HTTP/公共widget状态。Python独立生成两层zlib私有头与正文
金标，只证明压缩互通，不声称独立Matroska muxer或设备验收。
