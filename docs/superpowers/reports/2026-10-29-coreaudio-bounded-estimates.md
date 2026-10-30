# CoreAudio 有界估算与低采样率 MP3 帧数（2026-10-29）

基线 `d514997992fda10b4062f568ab511ea084fe2aae`，工作分支 `codex/coreaudio-bounded-estimates`。延续P03/P08可控资源实现，不改另一聊天iOS恢复，不推送、不发布，已提交并合并至本地main；见[合并与清理记录](2026-10-29-coreaudio-merge.md)。

## 实质实现

AAC/MP3原先把容器duration当作PCM帧数来源。估算会随任意长时长增长，六声道极值乘法可超出Int范围；iOS非batch转换还把估算结果用作UInt32帧容量。原生renderer虽能拒绝一般过长时长，估算先于拒绝，不能保护估算本身的整数运算。

本轮将时长估算按已有固定帧契约计算，PCM字节预留和实际分配共用固定容量：macOS一个输出包，iOS保留原有一个包的额外空间；容器duration不参与内存容量计算。FLAC继续从帧头取得精确帧数；DTS/Opus/Vorbis不变。不改变公共错误、资源限额或默认候选开关，也不证明系统A5上界。

进一步修复低采样率MP3的真实配置：MPEG-2/2.5 Layer III在8/11.025/12/16/22.05/24kHz每包576帧，MPEG-1为1152帧。配置、输出容量与时间映射保持一致，避免把36ms输入估成72ms、拒绝40ms窗口或把两个输入包映射到一个输出间隔。[FFmpeg header实现](https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/libavcodec/mpegaudiodecheader.c)提供格式依据；本机使用libmp3lame生成真实16kHz/32kbps单声道帧，经CoreAudio实际解码验证。

AAC 960帧实验配置在当前CoreAudio上返回invalidConfiguration。原始失败保留，未通过改写验收预期宣称它已支持，也不将独立ASC解析器视为解码资格。本轮保持原AAC-LC1024帧路径，不扩展HE-AAC、AAC960或其他profile资格。

## 回归与验收过程

新增共享测试3项：AAC立体声/六声道与MP3时长极值的有界估算；真实AAC/MP3在不同容器duration下的PCM容量、帧数、时间和每块首样本抽查对照；真实16kHz MP3的576帧解码及40ms窗口进展。RED先检查安全边界，仅修复后才执行Int64极值及实际分配，未故意造成进程崩溃或巨量分配。

首轮两项RED均失败。初修后的共享类9通过/1失败，原因是测试复用reset后的CoreAudio实例做精确PCM对照，存在历史状态差异；改为每种metadata从新建codec初态开始后，真实AAC/MP3时间、帧数、字节数及每块首样本逐项相等，没有增加浮点容差。AAC960探测失败后拆分MP3回归，确认72000us不等于实际应有36000us，随后修正帧配置。随后共享类10通过/1失败：首块实际47帧来自解码器初始裁剪，不能要求它等于完整576帧。保留首块正数且不超过576、后续严格576、时长按实际帧数以及40ms窗口实际进展断言，最终共享类11/11通过。全部原始失败保留。

最终集中矩阵203/203通过、0失败、0跳过，xcodebuild退出0；五类分别为共享音频11、容器输出14、媒体读取10、macOS系统音频110和managed管线58项。导出的唯一实际身份与预期逐一一致，五份冻结候选源码哈希仍匹配。当前完整macOS规范套件有921个运行身份，本轮没有宣称全部921项重新执行；源码镜像发现数iOS884/macOS928仅用于发现校验。

iOS Simulator arm64的config-only与build-for-testing均退出0，未启动模拟器或设备、未执行iOS运行测试。复用本聊天已有DerivedData；最低系统/真机资格不由编译证明。源码镜像与历史来源通过；消费者工具46项中45通过、1项因 `local historical focused evidence is not present in CI` 跳过，readiness工具15/15通过。

| 阶段 | 通过 | 失败 | 跳过 |
| --- | ---: | ---: | ---: |
| 异常duration RED | 0 | 2 | 0 |
| 初修共享类（reset对照问题） | 9 | 1 | 0 |
| 冷启动PCM抽查控制 | 1 | 0 | 0 |
| AAC960探测（不支持） | 0 | 1 | 0 |
| MP3低采样率 RED | 0 | 1 | 0 |
| MP3首块priming断言修正前 | 10 | 1 | 0 |
| 最终定向共享类 | 11 | 0 | 0 |
| 最终集中五类矩阵 | 203 | 0 | 0 |

保留最终矩阵的28条QoS优先级倒置警告及SDK/Swift警告；iOS日志另有 `error: the following command failed with exit code 0 but produced no further output` 的SwiftCompile异常诊断，整体build-for-testing仍退出0。报告不声称零警告或日志无错误文本，也不为消除诊断而改动另一聊天的DASH/iOS测试。

台账结构检查退出0，require-ready继续退出1、releaseReady=false；102行资格和nextAction与基线不变，仍为67 implemented/34 partial/1 unreviewed，69 not_run/30 external_missing/3 failed/0 passed。生产源码身份为 `12e4534abbc667e5090346d55899c6f072b9af3b9b79c2db4359f0b00eb2fbbf`。仅为CAP-FORMAT iOS/macOS及PERF-BASELINE追加报告引用。

原始阶段摘要、失败活动、压缩日志、最终源码与构建二进制哈希、实际身份和审查记录保存在[证据目录](evidence/2026-10-29-coreaudio-bounded-estimates/)，由SHA256SUMS绑定。完整xcresult留在 `/private/tmp/yl-coreaudio-bounds/`；早期失败未追认未采集的二进制身份。新增证据引用曾缺kind字段导致结构检查退出2，修复为kind=report后原验证器通过，操作失败也保留。

## 保留未完成项

P07完整映射/独立目标帧及容差、物理DV链路，P06授权/证书/素材，最低系统/设备、32位/Intel、热稳态、物理音画/字幕同步及外接保护输出继续开放。P08历史119.084ms READY因果与系统内部A5资源界尚未闭环；远程CI和完整发布资格未完成。另一聊天iOS恢复不在本轮范围。台账不得因本地修复提升完整能力资格。

独立复审未发现生产P0–P2；指出P3为PCM抽查描述过宽，已限定为每块首样本，不宣称完整PCM逐样本等同。同一审查者已核对203项实际结果、五份源码哈希及iOS仅编译收据，P3关闭，无剩余可操作发现；上述资格边界由本轮继续保留。
