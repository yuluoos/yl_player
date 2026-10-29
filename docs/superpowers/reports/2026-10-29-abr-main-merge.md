# ABR 分支合并至 main

用户明确要求合并到main后删除工作分支/工作树，不发布。合并对象：main 45e31091 与 codex/abr-recovery c7fad9c2；共同基线71018fd5。保留两边提交和全部原始验收记录。

代码自动合并，唯一冲突是发布台账。逐项合并双方证据字典与行引用，102行implementation、verification和acceptance在双方一致，全部保留。Android ABR的两种nextAction合并保留真机API24、重复、auto/caps/fixed与输出验证；iOS采用最新事务诊断待办。每行最多20条引用的约束不变；超限行由本报告承接，完整双方/合并引用和nextAction保存在[ledger-merge-map.json](evidence/2026-10-29-abr-main-merge/ledger-merge-map.json)，所有旧证据条目及文件保留。

合并后重跑网络工具155、消费者46、台账15项全部通过；当前/历史原生目标与源码一致性检查通过。首次网络测试受沙箱禁止本机监听影响而失败，原始错误保留；允许本地监听后同一源码全套155通过。414份ABR最终验证输入哈希匹配，复用其macOS223/iPhone248历史原生验证，不冒充本轮重跑真机。新增主分支的其他能力不因此获得验收。

[最新ABR报告](2026-10-29-ios-transaction-metrics.md)和历史证据均保留：原配置未恢复高档、恢复控制一条快速取消未关联仍严格失败；设备/授权、物理音画和稳定性缺口保留，旧终末停顿不重新列入。没有放宽门槛。

合并后生产源码指纹：`83c8ad3fe1693f53b58ff238ccee7d24615eea80c80cc5f59b3f65595e8c7bb3`。发布台账重新绑定该指纹；要求sourceMatches=true、releaseReady=false，台账与性能--require-ready保持退出1。清理仅针对codex/abr-recovery和本聊天的remaining-acceptance工作树；另一工作树保持不动。清理前保存忽略目录中的实施笔记到主目录.superpowers/archived-abr-recovery-c7fad9c2，生成缓存可重新构建；完整验收原件已提交且临时原始采集仍保留。不推送、不发布。

全量git diff --check命中一份历史原始XCTest日志的CRLF尾空格；该文件与工作分支逐字节一致，保留原件不改写。源码及报告范围检查通过，完整诊断与限定范围记录见diff-check.json。
