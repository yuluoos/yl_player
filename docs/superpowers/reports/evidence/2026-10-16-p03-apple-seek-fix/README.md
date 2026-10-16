# P03 macOS 公开 Flutter seek 采集与原生回归续做

基线 `dea89b7d3c75638c0674605d56402d4aaecc1e89`；Apple M1、macOS 27.0.1。
本轮延续获批 P03 Task 7，避开长播放和弱网 ABR。最终证据按独立 run 保存，不覆盖此前失败。

## 根因与修复范围

原生 retirement 回归实际失败于 `YlFallbackBackend` 构造的硬件证据准入，
纠正上一轮报告将失败定位到 `YlPreparedFallback` 的描述。生命周期测试替身
只提供旧 Boolean，默认 `hardwareEvidence.unknown` 被生产策略正确拒绝。
三份测试镜像补上明确的受控替身证据；它不构成硬件支持证明，生产准入未放宽。

公开 seek 采集有两个问题：nil controlTimebase 被错误视为速率零，实际 renderer
有效速率为一；读回为空时继续恢复播放会越过目标窗口。新增同层暂停读回时基、
原始有效速率记录，以及暂停状态内的有界重试。实际音频位置不再因空读回而推进。
seek 创建新层时必须先等待首帧就绪。就绪还不代表画面已到达显示目标；冻结后
若仍为空，会归还显示时钟让已排队画面完成呈现，下一轮再冻结读回。整个有界
恢复过程不恢复播放器/音频，不重新发布或替换像素。

最小 SDK 复现显示清除 controlTimebase 为 nil 后 renderer 有效速率变零，
提前设置速率一或等待也不能保留默认行为。因此原本隐式的主机时钟在验收表面
生命周期内保留为显式主机时钟，读回后恢复到速率一；已有停止时基仍按对象身份
归还。拒绝非零自定义时基及独立所有者替换，不替换表面、像素或解码器。

## 证据边界

这是显式 opt-in Debug、clear 内容、同产品构建和同会话的受控快照协议。
采样仪器调整显示时钟，因此不能代表完全无仪器干预的连续显示或物理音画同步。
`paused-layer-timebase-v1` 和逐像素 `displayRate=0` 必须同时存在；旧数据保持
历史状态，不转移到新协议。iOS 真机正向硬件、release/完整格式矩阵、物理输出、
独立参考及持续热资格仍开放，P03 Task 7/8 不整体标记完成。

## 已验证结果

- `native-consumption-verified-summary.json`：最终受影响原生定向回归 43/43，零失败、零跳过；此前41/42项中间回归同样保留。
- Flutter example `test/`：76/76；Python media matrix：48/48；Dart 分析与公开 API 检查通过。
- `public-final2`：历史六控制 raw 6/6、框架/身份/制品稳定性通过，但后续同包负例
  仍复现间歇缺口，不能代表最终闭环。
- `negative-framework-final`：原始 3/6，VP9 seek1250 提前超时，未到故意框架失败。
  独立复核将此列为 Important；新增真实层恢复回归 RED→GREEN 处理。
- `public-final`：首帧就绪保护前 raw 4/6，AC-3 seek1250 读回超时，保留实际暂停位置及 trace。
- `public-trace` / `public-trace-retain`：定位用旧协议运行，不被新门禁接受；不作最终证明。

原生 RED/GREEN、最小 SDK clock diagnostic、失败构建和失败公开运行完整日志随档保存。
`ready-red` 因首次编辑命令工作目录错误运行了旧测试并通过，不能作为 RED；
真正 `ready-red2` 明确复现冻结空层的错误，最终 41 项回归覆盖该断言。

## 间歇失败的显示条件

`public-repeat-verified` 在恢复时钟生效后仍失败3/6，因此未以单次六通过收尾。
随后 `visibility-diagnostic` 的六通过记录显示窗口在当前桌面且未遮挡；
`visibility-repeat` 的失败记录则明确 `space=false, occlusion=false`。准备好画面
并不代表显示目标当前可见，这一差别解释了间歇空读回。

最终 macOS 方案只调整已核验进程内唯一的 Flutter 窗口：临时400×260角落浮动、
跨桌面/应用可见，不激活应用、不切换桌面、不更改其他窗口；关闭几何自动保存，
结束恢复本窗口原 frame/minimum/level/collectionBehavior/autosaveName/visible 状态。
保留像素时必须实际 `windowVisible=true`，原始门禁同时要求窗口策略标识。
历史记录缺少新可见性字段，当前严格重放不再接受，原始 result 不改写。

## seek 后音频启动条件

窗口修复后的独立 `window-public-repeat` 仍失败4/6：AC-3 seek2250 的窗口可见，
但在真实音频输出启动前就公开暂停，消费时钟持续 invalid。固定等待150ms不足。
最终改为在原有两秒有界采集期限内先观察当前 generation 的实际消费时钟就绪，
再公开暂停。运行中的就绪观察只决定暂停时机，配对像素证据仍另读暂停时钟。
新增两项 Dart RED→GREEN 覆盖提前暂停和就绪超时；生产音频调度保持原样。

原生结果包含一条容器输出测试的 QoS 优先级倒置运行时警告，测试无失败或跳过。
API 检查首次遗漏 `--root` 的调用错误也保留，纠正参数后通过。

## 最终同构建对照

`final-controls-audit.json` 独立核验四个不同 runId、同一产品 SHA、运行后真实 bundle 未变：

| 运行 | 原始六控制 | 框架 | 总体范围门禁 |
| --- | --- | --- | --- |
| consumption-public-final | 6/6 | 通过 | 通过 |
| consumption-framework-negative | 6/6 | 故意失败 | 拒绝 |
| consumption-identity-negative | 0/6，播放前身份错误 | 未执行成功 | 拒绝 |
| consumption-public-repeat | 6/6 | 通过 | 通过 |

两次正向各自覆盖同会话实际像素、PCM、消费时钟、完成、三次 seek 和释放。
身份负例的运行时 `artifactsUnchanged=false` 表示身份核验没有成立；主机独立复核
确认四次的实际 bundle 都未变。受控 runner 在状态写入后终止自有 app，记录的
`processExit=-15` 不是 Flutter 通过凭据；门禁读取身份绑定的框架最终状态。

一次独立复核提出的 Important（间歇 seek 空读回）已在同一次修复流程内完成
真实层恢复、窗口可见性及音频启动条件的 RED→GREEN 和上述同包实跑。没有
Critical 或延期 Minor。复核未判断的更广格式/热资格及无仪器/物理/保护内容范围
仍开放；父任务负责构建隔离、iOS 编译和最终归档核验，不把未评估项算作通过。
历史失败与当前严格重放的差别见 `replay.json`；原始 result 文件保持不变。

普通 Debug 和显式传入验收 define 的 Release 都构建通过，三类采集/时基/窗口桥符号
均为零；opt-in Debug 三者均存在，三个制品都包含真实产品 registry。
`variant-absence.json` 保存实际二进制 SHA 和符号计数。这是编译隔离检查，
不代表 Release 音画或完整矩阵验收。构建日志保留既有网络配置等编译警告。

iOS Simulator opt-in Debug 由 XcodeBuildMCP 编译成功（`ios-build.json`，零错误、
19条既有编译警告），未启动模拟器，不作为 iOS 视频硬件正向或真机播放证明。

最终归档重放核验19次独立历史及四组对照，11份最终源码摘要一致。
`SHA256SUMS` 覆盖本目录所有其他文件；完整原生 xcresult 和产品构建留在本机
`/private/tmp/yl-p03-seek-fix-20261016`，仓库保存压缩日志、结构化测试结果及原始采集记录。
