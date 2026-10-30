# 独立综合复审：POSIX54 后高档重试与温和带宽对照

基线：`e4c93978`；候选：本轮未提交工作区及 `/private/tmp/yl-reset-retry-control` 对应证据。按 requesting-code-review / consolidated-acceptance 执行本轮一次独立综合复审。审查者未修改生产代码，未运行真机、重新构建或执行完整原生矩阵。

结论：未发现本次注释、诊断工具、测试、报告和台账变更中需要修复的重要正确性问题。可以保留本轮诊断结果并归档；这不是播放恢复、预算耗尽恢复、连续性或发布验收通过。五轮严格验收与复算仍为 0/5，releaseReady=false。

## 范围与判断

- 核对全部基线差异及新增 `rendition_retry.py`、`test_rendition_retry.py`、计划、报告；生产 Swift 仅将 source0 注释修正为“无已记录取消错误”。运行逻辑、预算 2、带宽/窗口/缓冲/退避/准备/票据门槛和严格媒体验收器未变。
- 新诊断先经过既有 v7 边界、错误来源、身份、字节、成功事务完整性和全关联检查。以设备 uptime 上严格晚于 downstreamTerminal 的 admission 计为后续新请求；同时刻及已在途请求单列，其他代理保存 proxyID+requestID。未将服务器绝对时间与设备时间相减，也未将其他代理流量当作原 item 自然重试。
- 同资源统计明确为资产路径层面的请求观察，不声称 Foundation 事务重试或 AVPlayer 私有算法根因；结果始终 rootCauseEstablished=false / capabilityAccepted=false。缺证据的 normal 和 budget-late-throttle 拒绝输出“无重试”，没有将缺失当作零。
- 报告保留原始三轮和后移阶段两轮的设计差异、预约/安装变异、原始失败及能力缺口。75k 控制和首 50k 轮未形成目标再次降档，不能用最终高档或 EOF 升级为预算恢复通过；报告遵守此边界。
- normal 的新自然双事务只有一条已解析服务器请求，第一事务 Foundation 报告请求头 309 字节、响应计数零且缺响应日期，第二事务正文 8391 字节、整体任务成功；严格指标失败仍保留。没有回填旧 v2 缺失值或推断真实发包次数。
- budget-late-throttle 的上游 1:60 / -1001 与 map 无响应证据支持连接超时观察，但不能定位 Wi-Fi、主机或服务器内部原因，也不能归因于尚未到来的第二降速或回环 POSIX54。报告未作这种归因。

## 独立执行与复用证据

独立执行：

- `python3 -B -m unittest discover -s tool/playback_network -p test_rendition_retry.py -v`：3/3 通过。测试覆盖严格时间边界、在途请求、同资源/同档区分、其他代理复合身份、服务器时间平移、缺关联和旧版错误来源拒绝。
- 另以成功请求缺 metrics 的输入探测，正确抛出 `proxy successful transaction metrics incomplete`，未返回无重试结论。
- 从五轮原始 MPD、代理边界和服务器请求重新调用诊断，输出与 retry-analysis.json 一致；normal 因成功事务不完整拒绝，budget-late-throttle 因关联不完整拒绝。
- 440 份最终来源和 438 份构建来源逐项哈希匹配；差集仅新增两份宿主 Python 文件，438 份共同来源未改变。307 份 iPhone 构建制品哈希匹配，五轮回执绑定同一制品；59 份媒体原始证据哈希匹配。
- 49 组历史 SHA256SUMS 与基线逐字节一致，10,273 条归档内容哈希匹配。
- 102 行台账 implementation / verification / acceptance 与基线一致，没有升级。选定 iOS 256、macOS 231 用例预期身份与实际身份完全相同，均无失败或跳过。
- 当前证据归档快照 256 条 SHA256SUMS 全部匹配。此检查早于本复审文件加入归档；加入后需按现有归档流程刷新并核验最终清单。

复用并检查了同候选修订证据：网络工具 206/206；独立消费者 45 通过、1 条既有 focused 历史证据缺失跳过；来源注册 883/927 仅作来源检查，不当作执行数。选定原生矩阵 iOS 256/256、macOS 231/231 的运行警告保留。台账/阈值结构检查及 15 项台账回归通过，require-ready 退出 1 符合未就绪事实；初次 nextAction token 格式检查失败保留于 initial-*，不抹除失败历史。

## 仍未验收

- budget-throttle、budget-mild、budget-late-mild 未建立安装后再次降档的目标预算场景，严格失败。
- budget-late-throttle 原生退出 65、末位置 51.099435 秒、width=0、未完成；末次发布 54.083785 秒至帧观测结束 99.420221 秒间隔 45.336436 秒，安装后代际 1 无新帧。51 条任务无服务器关联，其事务字节计数均零；177 条已接纳服务器请求均完成记录，末次结束 profile 51.955550 秒。不能用此前最大发布帧间隔或空替换边界掩盖尾部无帧。
- normal 虽观察到两次安装、高低高及高档尾段，仍因自然双事务响应指标缺失严格失败。
- 高档自然恢复稳定性、预算耗尽后的再次恢复、更多故障与生命周期竞争、历史双事务/macOS 就绪超时仍未关闭。设备、最低系统、实际网络、授权素材和物理屏幕/音频校准缺口保留；continuityAccepted、physicalOutputVerified、audioSynchronizationVerified、capabilityAccepted 不得升级。
- 没有证明可安全改变播放行为的修复，本轮只完成分析口径与注释改进。未授权发布的边界不变，不重新建立已删除的旧终末停顿待办。
