# 独立综合复审

Reviewer: fresh-context `gpt-6-astra`, high；只读；未运行构建、原生、GPU或FFmpeg负载。
Range: `978c2c5c3872d5570e3bd1a01f1a3d2e80d08f44..7e1ded9d117819f85e505860c2133e89c8b3253f`。
覆盖计划五项 Review Focus、代码、报告、ledger、实际解码/映射 trace 和最终 ABR 收据。

发现 Critical 0 / Important 1 / Minor 0：默认 foundation 中新增解码探针只检测 FFmpeg/runtime工具存在，没有确认开发库/API/libx265，可能让正常非研究环境 setup ERROR。

修复：真实解码测试显式要求 `YL_RUN_DECODE_PROBE=1`；默认 skip，不隐式增加开发依赖。增加默认关闭/显式开启的行为测试；默认关闭测试先失败，再通过（2/2）。本机最终 Dolby 受影响全套将显式开启探针；结果见 validation.json。没有降低显式启用后的依赖或解码检查。

其余结论：trace 保留同批完整行，不能解释历史119ms；生产所有权、caps/fixed、取消、回退未更改；实际解码使用包身份、PTS、独立parser POC及真实YUV哈希，没有将包数冒充像素质量。FEL2908/P56314/mapping2908的trace hash匹配，FEL所有BL/EL PTS/POC对应，2114重排。ABR末次320→640→320，无恢复升档；769826bit/s不能证明私有策略原因。完整DM/trim/目标映射、A5、物理DV等保留开放。

按集中验收策略仅一轮综合复审；修复由失败→通过的定向测试和受影响完整套件验证，未重复派发复审。


## 集中验收失败后的定向修复复核

原 reviewer 对 cb543135、d011e11b 及最终 HLS/原生测试修复进行定向复核，未重复全量审查；无新增 Critical/Important/Minor。

提前质量校验位于 willCommit 和资源交易之前，规则与构造相同；失败候选由 YlOpenCoordinator 取消/释放，旧引擎与 peer 不退役。回归同时要求 willCommit=0、旧 AVPlayerItem 身份不变、公开会话/播放意图/first-frame 不变。测试格式 hint、稳定错误码和显式 FakeSession 证据仅适配既有契约；原硬件 skip 谓词/消息不变。完成计数保留全部 publication，状态转移覆盖 replay/new-session。结论为代码复核，不代表运行通过；实际结果由 validation.json 记录。

最终控制意图断言调整由同一reviewer定向核对，无新增阻断：已知不可能满足的约束应在构造前拒绝；Pause/Seek/较新Seek/会话/继续出帧断言保留，相邻真实退役后构造失败并恢复控制的测试未改。实际GREEN仍以运行记录为准。

后续运行暴露该真实回滚用例的后续AV播放依赖 example.test 占位地址；最后仅改为仓库已有本地MP4及有界实际播放状态等待，实际退役/构造失败/恢复断言保持。此夹具修正经自查与整组8/8验证，原失败保留；未新增综合审查轮次。
