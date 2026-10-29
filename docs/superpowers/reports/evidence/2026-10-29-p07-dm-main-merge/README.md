# P07 本地合并核验证据

实现提交 `781b93cf1065c477a8be5118eced68bda9e4040c`，基线 `fa696c97332fd5f4c3134640f6a046caeac23ec0`。`merge-identity.json` 绑定合并树及检查结果；本目录随后以仅文档提交留在 main。原候选及全片数据在相邻 `2026-10-29-p07-dm-color-state` 目录，不覆盖历史结果。

- `precommit-identity.json`：11 个候选文件、原始证据、报告哈希和 102 行资格状态核对，提交范围完整清单。
- `precommit-state.log.gz` / `precommit-stream.log.gz`：7+22 项定向回归。
- `main-dolby-tests.log.gz`：在 main 执行 `YL_RUN_DECODE_PROBE=1 /private/tmp/yl-p07-dm-state/venv/bin/python -B -m unittest discover -s tool/dolby_reference -p 'test_*.py' -v`；91 项，90 通过，1 项默认未启用 CGL 跳过。
- `main-readiness-tests.log.gz`：15 项通过；`main-checks.json` 保存各命令与实际/预期退出码。
- `final-*`：补入合并报告引用后，15 项台账复测、结构/source 检查、require-ready 退出 1、diff 检查；全部原证据哈希和 102 行状态再次核验。

所有 `.gz` 文件为原始日志字节的无损压缩，`SHA256SUMS` 包含本目录其他全部文件。未重新运行设备矩阵、物理 DV 或真实压缩 DM；没有推送/发布或操作另一聊天的 iOS 工作。
