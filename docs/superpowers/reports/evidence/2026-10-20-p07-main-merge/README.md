# P07 合入 main 统一验证证据

合并前main `86143754`，P07 `a0578861`，候选树见tested-tree.txt。主报告见[合并记录](../../2026-10-20-p07-main-merge.md)。validation.json记录实际命令、预期退出码、验证范围和未执行项。

- foundation-summary.json：从完整原始日志提取的18个Python套件及10个Dart/Flutter子运行计数。600 Python通过/1原有CGL跳过，2318 Dart/Flutter通过。
- additional-results.json：串行的HDR/Metal、AirPlay/媒体拆分/头一致性、Rust、真实原片/参考及P08门禁实际退出码。门禁退出1表示仍缺正式验收条件，不当作测试通过或门禁放行。
- preservation.json、verify_merge.py：逐路径保留证明、历史P07清单校验。旧清单按原提交解释，不因当前总览追加而改写历史。
- inventory-before.json、inventory-rebind.json：首次P08台账检查的旧P07报告hash失效，之后仅更新该hash。所有行/状态/产品源码快照保持。
- independent-review.md：一次只读集成复审，0/0/0。
- logs.json：所有原始文本日志的SHA-256及压缩映射。`.txt.gz` 是原字节gzip，不删失败/警告/跳过；用 `gzip -dc` 查看。additional-results.json的log为原名，压缩档路径由logs.json映射。
- real_regressions.py、additional_checks.py：本机实际执行驱动。引用本地研究缓存及固定inspector；跨机器须提供同hash资源并调整路径。未提交大型原媒体或构建输出。

SHA256SUMS使用仓库根相对路径，绑定本收据、归档日志和主报告；本清单本身除外。merge后的收据文件不影响已测代码身份。原始P07工作树及忽略的研究缓存保留，完整P07/CAP-DV-MAP/OUT仍未完成。
