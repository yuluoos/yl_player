# P07准入/错误子项：单次fresh review

Reviewer: review_p07_admission_final，gpt-6-astra/high，fresh context，基线38a1e44。只读审查全部tracked/untracked交付、P07计划/契约/ledger及收据；仅运行临时宿主metadata probe，没有设备/模拟器/GPU/解码/播放操作。

Verdict: scoped admission/error subset ready to merge；Critical 0，Important 0。数值转换前检查、固定FFmpeg扩展字段范围、配置/逐包L5调用点、709-Float布局、无丢FEL/BL回退以及报告边界均通过审查。已列源码/日志哈希均匹配，实际测试计数和typecheck exit符合收据。P07整体不完成。

## Minor及裁定

Reviewer建议完善typecheck复现命令记录，指出validation.json.commands没有两项类型检查命令。实现者接受该非阻断记录改进并延期整理入口，不改生产或重跑复审。

事实补充：完整驱动已在复审前复制到本目录`typecheck.py`，并在43路径交付清单中；并非只有临时目录中存在。它保留实际target/SDK/framework/source枚举，但含执行机器绝对路径，换机器需调整。因此剩余minor是收据主commands列表的直接可复现入口，不影响现有成功日志或验证结果。

## 未评判范围与实现者裁定

- 完整RPU规范/原生parser分类：桥接未重写/重编译；当前子项不构成全部ERR-09验收。
- 有效元数据继承、解码帧对应：未改，保持待验证。
- 完整NLQ/重采样/trim/CM和最终画质：缺原始FEL、独立参考和冻结容差，不能从准入通过推导。
- 目标峰值/黑位/色域与外接变化：本增量没有新增处理，P07相关任务继续未完成。
- 实际decoder/GPU资源耗尽：本次只检查拒绝路径及resource分类；未运行设备压力测试，也未发现新增降级回退。
- 物理DV信号和画面正确性：两条验收链分别未验证。
- 用户补充网盘样本真实性及golden适用性：实际媒体未取得和验哈希，候选线索不视为参考图。

Final Ruling: 接受上述未评判范围作为明确未完成工作，现有有限修复可独立提交；代价是本次不能交付P07完整目标。无Important修复轮次，没有再次派发复审。
