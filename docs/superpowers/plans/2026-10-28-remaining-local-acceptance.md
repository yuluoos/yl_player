# 当前条件下剩余项续查与集中验收

> 执行方式：executing-plans、systematic-debugging、consolidated-acceptance。用户已授权连续实施，最后集中测试和一次独立复审。

Goal: 在63f5a618上完成当前可执行的Android弱网续查、本机工程核对及发布证据同步。
Architecture: 沿用既有Media3和AVFoundation行为，仅修复有复现与因果证据的缺陷。
Tech Stack: Kotlin/Flutter/Python及既有验收工具。
Spec: ../specs/2026-09-20-playback-expansion-requirements.md；2026-10-26-remaining-acceptance.md。

## Global constraints

- iOS恢复由另一聊天负责，不修改其工作树、不占用其iPhone或构建目录。
- Android24/iOS15/macOS12、50ms/3帧、100ms时钟新鲜度、3s释放及默认关闭候选不变。
- 缺设备、授权、独立参考与未证系统根因分别保留，不提升完整组状态。
- 独立分支实施；不推送、不发布、不合并。实施期间定向检查，最终集中验收。

## Task 1: Android ABR续查

- [x] 核对设备与P02–P08开放条件。
- [x] 复核40秒旧请求/输出，复用另一聊天已提交120秒生成器，只读导出、不重复开发。
- [x] 独占TV模拟器执行公开入口短/长对照及auto/caps/fixed重复诊断，保留源码/产物/设备身份和所有失败。
- [x] 如有可复现缺陷，先RED→GREEN回归再最小修复；无因果证据不改生产策略。

## Task 2: 本机工程与证据

- [x] 复核P03剩余原生失败、P08 ready和系统资源上界证据；当前能修复的继续处理，未知保持开放。
- [x] 核对TV优化、RTMP独立peer及发布/消费者脚本，修复证实的局部问题。
- [x] 更新报告与分支源码身份；历史失败、缺设备和另一聊天未验收结果保留。

## Task 3: 集中验收与复审

- [x] foundation、Android JVM含可用RTMP、受影响公开集成、产物及接口检查；未变Apple生产范围明确复用历史证据，保留33项iOS失败。
- [x] 一次独立综合复审；修复后只重测受影响范围。
- [x] 归档检查点、日志和哈希；分别运行性能和发布require-ready并保留真实门禁结果。

## Review focus

- 短素材预加载与真实恢复能力区分，长诊断不改写40秒基线。
- 保留每次失败；不把采集成功写成CAP通过。
- 清理只涉及本轮进程/端口，不干扰另一聊天。
- 台账匹配本分支源码，不自动继承整组资格。
- 设备/系统资源内部上界不能由模拟器、mock或编译证明。

## 集中验收发现与修复

- CI/快速门禁漏选根pubspec.lock，消费者漏选根pubspec.yaml：真实workflow shell+Git变更回归先失败4个子断言；修复选择条件，并将门禁测试纳入foundation。
- 全新检出忽略gradlew/jar，pub get并不生成：两种原生入口先运行仓库固定Flutter3.44已有的 `build apk --debug --config-only --no-pub`，只准备构建文件、不编译APK。保持Gradle版本固定。新增门禁/缺wrapper/配置失败的RED→GREEN。
- Android真实回调测试探针遗漏新增onNetworkBytesReceived双参数回调，引起原生transport failure后15s等待超时。补齐该测试消费者及nullable bytes/延迟ACK单元回归；不改生产FIFO、5s ACK期限或原生测试断言。
- 首轮foundation环境被本轮运行脚本的YL_ANDROID_SKIP_JVM污染（非产品缺陷）。修正阶段环境，测试夹具显式清除其自行控制的API/skip标志；原始失败完整保留。

验证：定向脚本19/19与探针1/1通过；第二轮集中验证正在执行。Android先前已通过的progressive/HLS入口保留；仅重跑失败session-replacement及原未执行的multi-player/cadence入口。弱网8次采集未涉及这些测试辅助代码，保留原始证据，不重复构建采集。

- 最终foundation发现Android控制器成功工厂仍为schema7，实际握手为8；以AndroidCodec.schemaMajor保持成功夹具同步。原8项失败保留，整个根播放器1706项随后通过。其余foundation阶段、静态分析与452文件格式通过；设备补跑、独立复审及归档继续。

- 多播放器回滚旧断言期待network.failed，真实404按现有YlFailureMapper返回network.http_status.404；仅修正精确错误断言，原回滚和请求次数断言保留。
- cadence首次运行期间专用模拟器ADB shell无响应，健康检查8s超时；只关闭已核实的port5580进程，原测试退出79归档。重启同一只读AVD配置后只补测回滚/cadence，不重复完整矩阵。设备挂起原因未证，不写成产品修复。

集中执行完成：两段foundation覆盖全部脚本，Python650通过/2条件跳过，JVM613通过/0跳过，五个Android入口10项通过，8次ABR采集，Android消费者及9包dry-run通过。性能/发布结构均0、require-ready分别1；独立复审待完成。

最终复审完成：仅发现归档日志被Git忽略的P2，统一gzip后同一审查者定向复核306项哈希/解压/零忽略/零漏列通过并关闭。代码无剩余可操作复审项。接受并保留全部declined-to-judge范围；当前本机实施/验收任务结束，完整P02–P08和发布资格未完成。台账15项定向回归通过；前一次错误目录0项exit5另存，不作成功证据。
