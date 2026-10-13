# Matroska 内嵌 VobSub

延续已授权 P02 字幕切片：本地文件和 managed HTTP(S) Matroska S_VOBSUB 的发现、
TrackUID 选择和位图渲染。继续使用现有会话、Range reader、字幕 owner 和 PGS bitmap
数据/overlay，不新增公开类型、原生桥、依赖或网络入口。长播放和弱网 ABR 不在本次范围。

## 数据与时间

CodecPrivate 为 UTF-8 IDX 全局设置（允许 v7 注释头，也允许规范规定的不带头形式），
必须包含 size 和 16 色 palette；复用外置 VobSub 的中性设置约束。遗留 id/langidx/timestamp
仅作为有界元数据忽略，不读取旁路文件、不影响轨道语言或时间；非零 delay 不支持。
每个 Block 包含完整原始 DVD SPU，不能含 MPEG PS/PES 外壳、多个 SPU 或截断数据。
Track TimestampScale/CodecDelay 转换为微秒，直接作为 SPU 控制序列时间基准。
SPU 的 start/stop/alpha 等控制命令仍生效；可见区间取 BlockDuration（否则 DefaultDuration）、
下一包时间和 SPU 显隐的交集。无容器 duration 时允许 SPU 自带停止命令，最终无停止的
显示最多到现有 7 天边界。包时间非递减，同时间后包替换前包；不推断其他语言轨道。

## 限制与原子性

共享现有 Matroska 4MiB 字幕输入、64MiB 扫描、32 字幕轨/128 总轨等上限；VobSub SPU
最大 65535 字节、全局文本/VobSub 包数不超过 10000。CodecPrivate 最大 256KiB，计入输入。
解码复用外置 VobSub 的 8192 画布、4MiPixel 单位图、256 控制序列/包、50000 命令/文档、
10000 cue、64MiB RGBA 目录预算。跨外置/内嵌/多轨剩余 RGBA 预算在分配前传入。
拒绝压缩/加密/lacing/CodecState/BlockAdditions 和已不支持的 DVD 命令或非中性变换；
WebM/MP4 不接纳 VobSub。损坏或超预算保持旧目录和选择，取消/换源禁止旧请求发布。

## 验证与仍开放项

先用真实文件失败用例确认当前 unsupported，再验证解析时间/原始字节/私有头、像素与透明度、
容器及展开预算、独立 FFmpeg remux 样本、实际 HTTP managed 策略、公开会话 Flutter 像素与生命周期。
最后四包回归、静态分析、一次独立复审、冻结已测候选及限定范围 commit。
仍不宣称 DVD 菜单/高级效果、所有合法 VobSub 输入、manifest/live 分段、原生或设备/HDR 等价；
完整 P02 仍开放。

映射依据：[Matroska subtitles](https://www.matroska.org/technical/subtitles.html)，尤其 CodecPrivate
去除 IDX stream/timestamp 元数据规则。没有新增外部请求。
