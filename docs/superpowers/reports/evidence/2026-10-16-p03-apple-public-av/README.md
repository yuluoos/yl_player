# P03 Apple 公开 Flutter 同次构建音画验收 — 2026-10-16

本轮完成采集链路、严格门禁、API 注释及失败诊断，**尚未取得最终协议的六项全部通过**。不宣告 P03 完成，也不将历史通过结果迁移到新构建。当前版本的 macOS seek 输出缺口仍开放。

## 实现与身份

公开 `YlPlayerController` / `YlPlaybackSession` / `YlPlayerView` 驱动创建、加载、播放、暂停、三次 seek 和释放。观察器只装饰实际原生会话的 PCM 转换器并读取其实际挂载的 AVSampleBufferDisplayLayer；不替换纹理、强制解码器或绕开 managed 路由。

构建一次后冻结整个 Debug app 的代码与资源 manifest；产品和 Dart 测试明确共用一个 app SHA-256。进程核验实际 bundle 与加载的产品镜像（含 FFmpeg bridge），结束再次核验，宿主拒绝文件增加、删除和变化。最终状态必须来自 `binding.allTestsPassed`；raw 数据通过不能代替框架通过。

观察器及调用点只有 `DEBUG && YL_BOUND_AV` 同时成立才编译。PCM 装饰器透传原 bufferScope，保留实际计费并在真实输出缺少 reservation 时拒绝。公开 API 只补充注释。

## 采样协议修正

本机 Apple SDK `AVSampleBufferVideoRenderer.h` 明确说明 `copyDisplayedPixelBuffer` 在非零速率时返回 NULL（[Apple API](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer/displayedpixelbuffer%28%29)）。早期播放中读取偶尔取得像素，不能证明一个符合接口前提的采集协议。早期 6/6 记录均保留为历史，当前校验器要求 `renderer-paused-consumption`，不会升级旧结果。

最终协议通过公开 API 暂停，等待50ms让系统呈现状态落实，再读取实际显示层与 renderer.pause() 从输出节点冻结的消费位置，然后公开恢复播放。实际层 timebase 必须为零；音频必须为 paused/ended，不能采用运行中外推值。每150ms实际播放采一次，原七个8192帧 PCM 窗口、颜色/音频配对跨度和固定六控制分母未放宽。该协议验证暂停采样的内容与位置，不证明不间断播放或物理同步。

## 实跑结果与尚未完成项

- `macos-paused-settle`：最终协议、当前构建，身份核验和制品稳定性通过，总体验收失败，0/6。首项保留了全部阶段，但 seek0 的有效采样越过目标颜色段；第二项 seek1250 没有得到显示像素。未完成项仍在固定分母中。
- `unfinished.json` 保留超时前原生状态、消费时钟、PCM数、阶段、像素及读回状态。第二项已 completed、音频已消费到约4s；显示层320×180、ready=true、rate=0、无系统错误，仍返回空像素。根因尚未确认，不能把该缺口归因于设备或宣布修复。
- `macos-paused-negative-identity`：同一最终构建的错误身份在播放前被拒绝。最终协议的“raw6/6后框架故意失败”实跑尚未完成；Python门禁负例已覆盖，但不替代实跑。
- `ios-final`：iOS Simulator 包构建成功，运行时身份与制品稳定性通过；首项公开加载返回 `decoder.unavailable`，0/6失败，未通过强制软件解码绕过硬件准入。已关闭本任务启动的专用模拟器。
- 普通 Debug 制品无观察器符号，显式 opt-in Debug 有观察器符号；两者均确认存在产品 registry，检查不是空二进制假通过。Release显式带YL_BOUND_AV、arm64构建成功且无观察器符号，产品registry符号存在。首次通用架构构建失败日志也保留。

完整原始记录见各 run 的 plan、product-files、rows、status、result 和 flutter.log。`replay.json` 同时保存当时记录的通过值和当前门禁重算值。结果不同源于协议加强，原记录不改写。采集器主动结束自身GUI进程时 processExit=-15是清理行为，不是通过信号。

## 验证、复审和失败历史

Python48/48；Flutter公开API/view24/24；Dart分析无问题。普通 Debug 原生精确回归40项：39通过，1失败，详见 native-macos-final-summary.json 与完整日志。失败为 `YlPlatformServicesTests/testRetiredFallbackCannotClearCandidateTexture` 在现有 YlPreparedFallback 构造阶段抛出 `Playback operation failed`，尚未完成独立基线归因，不能称全套绿色。初次误选整个音频测试类的运行已停止，仅保留为中断历史。

单次独立复审发现 Important：PCM装饰器漏传 renderer 只向具体 converter 注入的 bufferScope。`macos-budget-red` 的真实输出断言失败，透传后通过该检查；断言继续保留。后续协议修正源于实跑诊断；未派发第二次复审。参见 final-review.md。

运行历史全部保留：public1暴露向后seek旧position跳过采集；public2超时且重建与运行重叠，身份无效；public3及早期final若干轮虽记录6/6，但属于旧协议。后续 live/awake/visible/root/diagnostic 轮次暴露 pump等待或缺少像素，不能算有效的“末尾框架失败”负例。最终 paused 轮次改用公开暂停，仍发生 seek 缺口。没有挑选成功轮次掩盖失败，也没有删除固定控制。

## 边界

采集API最低 macOS14.4 / iOS17.4，产品部署下限仍为macOS12 / iOS15。显示层读回不代表物理屏幕呈现；音频输出节点不代表扬声器延迟。release完整格式/网络矩阵、最低系统、Intel、真机、独立参考与持续热资格仍开放，所有结果 `fullAcceptance=false`。

工作起始HEAD1828616；另一会话独立提交P04为462254b后继续显式文件提交，未编辑其长播放/弱网ABR项目。source-provenance.json补充源码哈希，制品身份始终由实际文件manifest决定。

最终制品：macOS `ff0d56d2d740151f1317080960b41392dd2c85997ebe6e3f740779261c9ab02e`；iOS `9fb6e9ca61cb51de0e3d0748bdefa50ab4952813691509c4c9cce3fe1c2f9a0e`。两者都未取得本范围的总体通过。
