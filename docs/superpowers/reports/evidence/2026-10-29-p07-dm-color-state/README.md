# P07 DM 颜色头状态验收证据

基线 `fa696c97332fd5f4c3134640f6a046caeac23ec0`，未提交候选以 `candidate-files.json` 绑定实现、测试、固定依赖锁和说明；报告及发布台账文案不属于该代码快照。`SHA256SUMS` 绑定本目录全部其他文件，gzip 保存原始字节（包括错误和跳过）。不含媒体、库或探针二进制。

- `python-consolidated.log.gz`：NumPy 2.3.5，`YL_RUN_DECODE_PROBE=1 .../venv/bin/python -B -m unittest discover -s tool/dolby_reference -p 'test_*.py' -v`；91 项、90 通过、1 CGL 默认未启用。不是缺少 NumPy 导致的测试跳过。
- `rust-final.log.gz`：固定 libdovi 614c816、离线锁定 Cargo，Rust 3 单元 + 1 真实 RPU 生成/解析/三模式 CLI 测试通过。真实压缩来源仅为合成契约，不是公开压缩视频或物理输出。
- `readiness-tests.log.gz` 与文档归档后的 `readiness-final-tests.log.gz`：15 项通过。`readiness-final*.json` 和 `final-verification.json` 是最终报告/ledger 哈希更新后的结构与阻止发布结果。
- `p5-final.json` / `fel-final.json` 及对应 `.jsonl.gz`：最终探针全片盘点、解码序包身份和 PTS 排序轨迹。`build-final-receipt.json` 记录实际二进制 SHA；最终工具构建路径不同于首次构建，因此使用最终二进制重跑两份全片。两者均没有压缩 DM。
- `p5-color*` / `fel-color*` 和 `build-receipt.json`：首次构建实测，保留独立工具身份，不冒充最终二进制。
- `red.log.gz`：新模块不存在时失败；`rust-minimal-fixture-failure.log.gz` / `rust-contract-diagnostic.log.gz`：17 字节压缩夹具被固定库 25 字节下限拒绝。最终以合法 L1/L5 动态块构造足长压缩记录，库与生产实现未改变。
- `independent-review.json`：独立新上下文只读审查结论，逐条 trace/color/header 哈希与来源索引额外核验，无可操作问题。
- `qualification-unchanged.json`：102 行状态、验收记录和 nextAction 与基线逐项相同，仅新增 P07 研究证据引用。

宿主临时目录为 `/private/tmp/yl-p07-dm-state`，所有日志中相关路径只用于定位实际运行。固定解析库归档及公开媒体从主仓库既有缓存只读使用：

```sh
python3 -B tool/dolby_reference/probes/build_stream_inspector.py \
  --probes "$primary/.superpowers/sdd/2026-09-26-remaining-07-dolby/build-probes" \
  --output "$new_build_dir"
python3 -B tool/dolby_reference/stream_inventory.py \
  --media "$media" --sha256 "$sha256" \
  --inspector "$new_build_dir/target/release/yl-dovi-stream-inspector" \
  --dm-color --trace "$new_trace"  # FEL 实测另加 --layers
```

媒体 SHA 见各 JSON；P5 路径为 `.../build-probes/sol-levante-p5-1080p.mp4`，FEL 为 `.superpowers/sdd/2026-10-20-p07-public-resources/resources/fel-test-st-dl-p7-cmv4-v4.mp4`。trace 文件路径须不存在。

未改播放器/依赖/CI 的矩阵按集中验收规则复用 2026-10-28 同源码记录，不能将本目录当作新设备回归；iOS 历史失败和另一个聊天恢复工作不变。完整 CM/trim/映射、独立目标/容差、物理 DV、真实压缩流仍未验收，不推送、不发布。
