# P08 音频转换器暂存输入释放

基线 `0a4f4ac5`。按本轮用户选择继续 P08 资源释放与生命周期，修复实际所有者清理路径；不改恢复策略、容量门限或默认关闭的音频候选。

## 缺口与实现

`YlAudioRenderer.dispose()` 原来停止 output、清空 renderer 统计并退役 terminal PCM，却没有调用 converter.reset。`YlAppleCompressedAudioConverter` 的 pendingPackets/pendingOutputPackets 可以在转换等待更多输入或转换失败后继续持有压缩 Data 及预算 token。旧 renderer 仍被 Resource 或其他调用者持有时，停止播放并不立即归还这些输入额度。

修复在 output.dispose 返回后重置 converter，然后沿用 terminal 退役顺序。停止输出先于转换器输入释放，整个过程仍由既有 operations 锁串行化；disposed 标志保持幂等，不新增重试、兜底或额度。复用已有 reset 契约，不引入新公开接口。

新增共享测试使用持有真实压缩包与真实 ledger token 的转换器替身，分别覆盖 buffered 返回及保留输入后抛错。测试刻意保留 renderer/converter 引用：修复前 dispose 后仍占64字节；修复后立即归零，重复dispose仍为零。该用例证明待输入所有权的释放，不冒充实际设备音频内存测量。

## 验证

| 检查 | 结果 |
| --- | --- |
| 新增原生回归 RED | 实际执行1项失败，dispose后64字节未归还；原始xcresult摘要与日志保留 |
| 修复后 macOS 定向原生 | 17/17通过，0失败、0跳过，xcodebuild退出0 |
| 共享夹具/示例同步 | 通过；iOS900、macOS944个原始方法清单匹配 |

17项包括共享音频类的12项，以及5项停止/重置/旧回调相关测试；涵盖真实AAC、MP3、DTS、Opus/Vorbis既有转换和额度行为、转换后超限、转换前背压、网络取消、终末PCM退役及旧回调隔离。只运行受影响范围，没有重复全套或长播。原生构建的已有Swift/XCTest最低链接版本等警告保留，未将警告抹去。

实际运行平台为本机macOS arm64。iOS测试源码镜像同步，但本轮没有iOS编译或运行证据；不将macOS结果写成iOS、最低OS或物理设备通过。

## 证据与未完成项

[证据目录](evidence/2026-10-30-audio-disposal/)包含红绿日志、原生摘要及17项实际执行身份、当前源文件指纹、构建产物指纹和夹具检查结果。完整结果留在 `/private/tmp/yl-audio-disposal/red.xcresult`、`green.xcresult`。

台账刷新生产源码绑定，为Apple的REG-BUF/REG-LIFE与PERF-BASELINE追加本报告，102行implementation/verification/acceptance状态不变。资源统计归零不证明系统内部A5上界；未证明系统音频分配、完整后端资源上界、历史119.084ms READY根因、物理音画连续性或热稳态。转换器上下文最终销毁及系统保留也不由本次输入队列清空测试宣称完成。候选保持默认关闭，完整P08与发布资格继续开放。未提交、未推送、未发布。
