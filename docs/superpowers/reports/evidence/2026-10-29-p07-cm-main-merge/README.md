# P07 CM 与帧来源本地合并证据

实现提交 `00be1a3a6993049d72cf9afb02bc4af031378a86`，基线 `9687fab8736b4bc0a225058832069140c3b31efe`。`merge-identity.json` 保存快进与树身份，随后仅文档提交补记录。

- `precommit-identity.json`：17 个候选文件、原证据、报告及 102 行状态验证，指定提交范围。
- `precommit-checks.json` 与日志：38 项定向回归和台账结构检查通过。
- `implementation-commit.log.gz` / `merge.log.gz`：实际本地提交及快进结果。
- `main-dolby-tests.log.gz`：合并后 `YL_RUN_DECODE_PROBE=1 /private/tmp/yl-p07-dm-state/venv/bin/python -B -m unittest discover -s tool/dolby_reference -p 'test_*.py' -v`；101 项，100 通过、1 CGL 默认未启用跳过。
- `main-readiness-tests.log.gz`：15 项通过；`main-checks.json` 保存结构和 require-ready 的实际退出码。
- `final-*`：补入合并记录后台账 15 项通过、结构/source 有效、require-ready 退出 1；原始证据与 102 行状态再次核验。

日志 gzip 无损保存，`SHA256SUMS` 绑定本目录其他全部文件。原始长素材 trace、合成夹具、Rust 测试和独立复审保留于相邻 `2026-10-29-p07-cm-frame-provenance`，本次按同候选身份复用。未重新运行长素材/GPU/设备或 iOS，不把工具检查当作完整 Dolby/发布资格。未推送、未发布。
