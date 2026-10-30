# 取消任务收尾与恢复重复验证

沿用用户已授权实施、TDD和集中验收；基线92dec97f，不发布。
已确认：close/cancelAll移除TaskRecord并立即封存trace，导致真实取消后Foundation metrics/didComplete回调找不到trace。修改仅DEBUG诊断所有权，不阻塞播放取消、不改变2次预算/955000bps/双8秒等原策略与任何验收门槛。

- [x] 真取消红例→DEBUG任务独立保留trace直到didComplete，播放侧finish冻结body/send字段但等待任务收尾后交付；active trace保留连接对象防止ObjectIdentifier复用；observer完成前capture pending不释放。
- [x] v4日志显式downstreamTerminal/taskComplete/taskOutcome及最终terminal；旧v1–3继续读取，v4成功必须任务成功和全部事务核心区间完整，取消缺指标不补造，服务器关联门槛不变。
- [x] 原生macOS/iPhone相关249/224矩阵、工具、消费者、镜像及独立复审，真实取消/late sends/observer重入/双事务保持覆盖。最终输入冻结后采集。
- [x] 用户确认准备后9分钟前台：新制品两轮normal再次降档恢复及一轮原配置；明确哪轮实际第二安装、帧连续性、取消任务收尾与服务器关联，不用诊断profile追认原配置。
- [x] 原始失败及缺设备/授权项保留，历史哈希、完整xcresult无损归档、台账更新与门禁核对，仍不发布。

本批实施及集中验收完成：工具188、消费者45通过1既有跳过、iPhone249/macOS最终224通过；mac首轮2失败保留。三轮严格1/3，两个再次恢复轮因快速取消关联仍失败；原配置单次自然恢复。34取消metrics全部保留，不代表所有事务完整或整体验收通过。详见本轮报告，不发布。
