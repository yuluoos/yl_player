# 独立综合复审：默认池取消与事务字节边界

基线：524f31a0。检查时间：2026-10-29。范围：本轮 Python 汇总/测试、canonical 原生新增测试与 iOS/macOS 对应块、case registry，以及当前已落盘的测试证据。只读检查仓库；本文件是复审输出。

## 发现

- **P2：首次取消结束断言缺少 observer 交付屏障。** `tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift:4134`（两个镜像同样）在 `wait(for: [cancelled])` 后直接断言 `activeRequestTraces == 0`。`cancelled.fulfill()` 位于 observer 内；`YlHlsProxyRequestCapture.makeTrace` 在 observer 返回后的 defer 才调用 `didDeliver()` 注销 active trace，再 `pending.leave()`。因此等待者可以在该清理前恢复并误报 trace 泄漏。已有 `testProxyRequestTimingRetainsTerminalOwnershipUntilObserverReturns` 也明确验证这一生命周期。建议在第一次取消 expectation 完成后、首次清零快照前调用并断言 `diagnosticRequestCapture.wait(timeout: 2)`；这是同步测试观察，不改变 transport race。单次通过并不能排除该时序。需同步 canonical 和两个镜像，并对最终源码验证。

## 已核对的正确边界

- `_byte_evidence` 仅处理通过既有严格校验的输入。任一计数正数分类 positive；两项明确零才 zero；其余 unknown。旧版本、无 metrics、零事务、v3 截断均显式区分；原始计数、时间状态仍完整保留。
- 原 `complete` 计算、格式/计数/时间一致性校验未修改。新增字节分类不填日期，不推断服务器关联；两个证明字段恒为 false，解释也明确计数不能证明物理传输或服务器解析。`proxy_boundaries` 原 successful-transaction 缺口仍进入失败分支。
- 原生对照新建 server/proxy/session，生产默认连接配置、无先行 task；真实 NWConnection 完整 GET + EOF 引发取消。响应门闩只防止取消前成功，并未先占 upstream slot。六轮均记录取消 trace 和显式同 URL followup；后者独立 correlation ID、同 resource token、成功 body 和服务器 trace ID 绑定。
- 未要求取消事务数量、未要求取消 trace 必须/不得出现于服务器快照，避免用人为断言挑选竞态结果。artifact 保留 capabilityAccepted=false、physicalOutputVerified=false。
- canonical 和两个镜像的新增方法块 SHA-256 一致：f572e517a2ed60695a914ae5e7c820ec5fca0e88f69c8d897a44ae2f58dfb3db（交付屏障修复后复核值）；整个文件有既有平台差异，不应要求全文件一致。

## 证据边界与当前验证

- 本次独立运行 `python3 -B -m unittest discover -s tool/playback_network -p test_transaction_metrics.py -v`：12/12 通过。
- 阅读 `tools-final.log`：200 通过；`consumer-final.log`：46 运行、1 skip，需在最终记录中保留 skip。
- 阅读 `native-probe-summary.json` 和 `native-probe-fixed-summary.json`：首次类型读取错误失败记录仍存在；修正类型后的 macOS 单例通过 1/1。该通过早于上面发现的交付屏障修复，不能当作最终源码完整矩阵。
- `parsedServerTraceIDs` 是显式 followup 完成后的快照，只能描述该时刻记录到的 ID。共享 fixture `DashHTTPServer` 使用一次 receive 解析头，并非完整 TCP HTTP 流解析器；取消请求缺失 ID 尤其不能推出未发送/未到达/永不稍后到达。本轮代码注释已限制为 snapshot；最终报告应维持该措辞。
- 尚未提供最终 iPhone/macOS 完整矩阵、两轮约 6 分钟采集、历史失败重算与完整归档/发布台账核对。因此这里不宣称本轮验收完成，更不宣称生产缺陷修复或物理音画验收通过。

## P2 修复定向复核

已检查 canonical 与 iOS/macOS 两个镜像：取消 expectation 后立即 `XCTAssertTrue(try XCTUnwrap(YlHlsMediaProxy.diagnosticRequestCapture).wait(timeout: 2))`，再读取 row 并断言 active trace 清零。capture 的 pending.leave 在 didDeliver 之后，故屏障准确覆盖所指出的竞态；此时 followup 尚未创建，不会错误等待新请求。P2 源码问题已关闭。以上原始发现保留，修复后完整运行证据待补。

## 当前结论

源码复审已无未解决问题；Python 诊断及原生对照未发现验收门槛放宽。最终证据到齐后继续同次复审，核对最终运行及历史失败/设备授权缺口的保留情况。不发布。
