# iOS 高档入箱后的恢复方案验证

基线 `fa636df4`，分支 `codex/abr-recovery`。本轮继续使用系统化排查、测试驱动和集中验收；用户要求保留失败、不放宽门槛、不发布。原报告 [ABR 恢复续查](2026-10-27-abr-recovery.md) 及其 242 份清单内证据保持不变。

## 结论

同 item 精确 seek 已验证不能解决本次未升档。同源重新准备并调用现有 `replaceActiveDash`，两次均使新 item 重新选到高档并完整播放至 120 秒。这是一条有实测依据的恢复候选路径，**不是已经完成的自动恢复产品修复**。

替换会建立新 item 和新的 access/error log 生命周期；不能说旧 item 的 penalty box 被清除。调用返回时内部 currentTime 曾为 0，随后回到替换事务捕获的位置，且存在 waiting 样本。操作期间没有连续采样，不能根据周期位置未回退或采样间隔推断无缝播放、黑屏时长、音画/字幕同步通过。

本轮完成诊断工具的操作身份和归因保护：只运行明确标记的一次干预；保存操作前记录；绑定每行 action；拒绝旧 host、未执行/失败操作及错误 item 身份；禁止把干预行用无干预摘要入口处理。没有把 35 秒定时或私有错误码匹配引入生产策略。生产源码、原始媒体、网络 profile、质量约束和验收门槛均未修改。

## 依据与假设

Apple [TN2436](https://developer.apple.com/library/archive/technotes/tn2436/_index.html) 说明错误日志与 item failed 状态的范围：仍有可用变体和缓冲时，不能依靠 failed 状态识别本问题。公开 [seek API](https://developer.apple.com/documentation/avfoundation/avplayer/seek%28to%3Atolerancebefore%3Atoleranceafter%3Acompletionhandler%3A%29) 支持定位和完成回调；[replaceCurrentItem](https://developer.apple.com/documentation/avfoundation/avplayer/replacecurrentitem%28with%3A%29) 支持更换 item。这些文档没有提供本实验所需的 penalty-box 清除保证，本轮没有使用私有 API。

假设 A：原 item 精确 seek 可以使同一选择器重新考虑高档。结果：seek 完成、item 未变，但到片尾仍低档，否定其对本次复现的修复作用。

假设 B：保留当前播放位置/意图，通过项目已有同源替换事务建立新 item，可以在已恢复网络下重新选高档。结果支持当前素材/系统下的候选路径；并未单独分离新 asset、新代理 namespace、新 item 各自影响，不能把结果归因于某个私有状态的重置。

## 不变条件和执行身份

- iPhone 18 Pro Max / iOS 27 Simulator，UUID `B4B1FA2D-8FFC-490D-8E1E-29EE3FEB5EB8`；Apple M1、Xcode 27.1。
- 原 `down-and-recover-v1`，SHA `4e4f256c59465f4a573d6ab1c48f7a7571294638025088d0cddba9325f5032ea`：0 秒 500000 B/s+40 ms，10 秒 50000 B/s+200 ms，25 秒恢复 500000 B/s+40 ms。
- 同一 120 秒 MPD，SHA `1be00f4b713ecdcaf00a5744ba344b6973d67db764e3f4aa65bdf613da46ceb6`。不延长弱网/恢复阶段、不修改分片、不强制选高档，peak 始终 0，forward buffer 10 秒。
- managed 启动保持先 prepare 后创建 AVPlayer；启动额外延迟 0。操作仅在 elapsed≥35 秒、已出现高到低、当前低档且记录 CoreMedia -12889 时执行一次。此条件只属于自有夹具诊断，不是面向任意来源的生产触发规则。
- 初始三轮使用 `source-initial/` 与 `source-identity.json` 对应探针；最终重复轮使用 `repeat-source-identity.json`，额外严格要求操作瞬间仍低档。初始三轮原始行也满足该前提。原始收据不按新摘要字段回写。

## 逐轮结果

| 运行 | 原生入箱 | 操作结果 | 后续高档 | 片尾 |
| --- | --- | --- | --- | --- |
| baseline | 是 | 无干预 | 无 | 120.053 秒 |
| seek | 是 | 35.147 秒调用；成功；item 未变 | 无 | 120.016 秒 |
| reload | 是 | 35.027 秒调用；新 item 安装成功 | 41.170 秒、节目位置 40.031 秒首次观测 640×360 | 120.059 秒 |
| reload-repeat | 是 | 35.061 秒调用；新 item 安装成功 | 41.543 秒、节目位置 40.029 秒首次观测 640×360 | 120.019 秒 |

首轮 reload 在操作前位置 34.411 秒，prepare/安装约 0.292 秒，调用后内部时间为 0；下一周期样本位置 34.701 秒，随后继续播放。这一位置来自事务实际提交时捕获的当前时点，不能以 prepare 之前的 positionBefore 断言精确落点误差。跨操作采样间隔 seek 约 0.405 秒、reload 约 0.544 秒；它们包含探针等待，不等于实际输出中断时长。各轮原生 timer→MoveAlternateToPenaltyBox→-12889 原始消息单独保存，`passed=true` 只指采集/清理/身份，不代表 ABR 完整通过。

重复轮 prepare/安装约 0.362 秒，调用后内部时间同样为 0，跨操作采样间隔约 0.614 秒。两轮从操作开始到首个高档样本分别约 6.143/6.482 秒；这是有干预的采样观察值，不是新的性能门槛。原生帧采样存在、各轮自然片尾、ownedProcessExited 与 binaryIdentityUnchanged 均为 true；所有 capabilityAccepted 仍为 false。原始及分析记录见 [本轮证据](evidence/2026-10-27-abr-penalty-recovery/)，分析并不覆盖操作期间未采样的输出。

## 检查与复审

- 网络诊断 Python 全部 89 项通过；benchmark Python 294 项通过。后续仅加强摘要归因检查，对受影响网络套件重新运行并保存最终结果。
- iOS/macOS 最终探针 build-for-testing 均 exit 0。当前测试镜像一致，iOS 822/macOS 866 是声明数量，不是本轮运行通过数。
- macOS 实际执行复用路径六项契约，6 passed / 0 failed / 0 skipped：音轨/metadata/ready、当前位置和暂停意图、pending seek 与迟到回调、固定选择与迟到回调、固定恢复失败/超时、非法替换回滚与恢复 private asset。无干预及三次干预的 iOS 运行另计。
- 一次独立综合复审检查代码、原始行、归因和最终台账，记录位于 evidence 下 review.md。完整归档 SHA256SUMS 绑定日志、源码快照、操作记录、请求、制品 hash、xcresult 与命令；日志无损 gzip，生成媒体以清单绑定原仓库素材。
- 生产源码身份仍为 `77fdcdc820e805edfbea670ac670c9181bb69defc7171b65a24716cab37dc37c`。未修改 Dart、产品依赖或原生生产源码；复用上一报告的 example 109、静态分析及产品完整矩阵，明确不是本轮全量重跑。既存 iOS 33 个解码/输出失败、1 skip 和其他性能/设备/授权缺口不变。

## 尚待完成与台账

CAP-ABR iOS 保持 `partial / not_run / acceptance=null`。新的 nextAction 记录同源替换已在当前模拟器获得恢复证据，但仍缺：不依赖私有日志或固定时间的可靠触发/退避预算；实际连续输出与音画/字幕同步；用户暂停/seek/切轨竞争在真实恢复中的覆盖；caps/fixed 全矩阵；DRM、AirPlay、最低系统和实机验证。现有六项契约不能替代这些端到端资格。

因此本轮不自动重建正在连续低档播放的用户会话，不添加未验证的生产恢复策略。也不将恢复后的新 item 成功覆盖原 item 的失败。其他设备和授权资源缺项保持开放；全台账继续 102 行、0 个完整通过声明，发布就绪仍为 false。没有发布、上传或打标签。
