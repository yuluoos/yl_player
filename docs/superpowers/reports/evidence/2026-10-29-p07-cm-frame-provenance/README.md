# P07 CM 状态与解码帧验收证据

基线 `9687fab8736b4bc0a225058832069140c3b31efe`；未提交候选以 `candidate-files.json` 绑定 17 个源码、测试、固定依赖锁、说明文件。报告和发布台账只补资格记录，不属于代码快照。`SHA256SUMS` 绑定本目录其余全部文件；gzip 保存原始字节，不丢弃失败与跳过。

- `consolidated-python.log.gz`：101 项，100 通过、1 CGL 默认未启用跳过；`YL_RUN_DECODE_PROBE=1`，临时 venv 使用仓库固定 NumPy 2.3.5，宿主 FFmpeg 解码探针实际执行。
- `rust-test.log.gz` / `rust-build.log.gz`：固定 libdovi 614c816、锁定离线依赖，Rust 4 项通过。
- `synthetic.rpus`、`synthetic-parsed.jsonl.gz`、`synthetic-state.jsonl.gz`、`synthetic-verification.json`：由本轮 Rust `examples/cm_state_fixture.rs` 生成的 4 个 RPU，通过真实 libdovi 后检查 2 个压缩记录的静态继承/动态过期/完整刷新/重排。不是公开媒体、真实压缩视频或物理输出；生成器和输入身份见 `fixture-receipt.json`。
- `fel-decoded.json` / `p5-decoded.json` 及 `.jsonl.gz`：最终工具真实全片软件解码及元数据来源。FEL 2908 对、P5 6314 帧，分别 2114 / 5392 个包重排；每条颜色/header/block 哈希、来源、解码包编号、PTS/POC 和总 trace 哈希经 `verify_decoded.py` 核对，结果见 `decoded-verification.json`。
- `fel-inventory*`：实现期间全片 schema 5 盘点，使用上一轮已验证探针；最终解码运行使用本轮构建，其身份另由 `inspector-build.json` / `decoder-build.json` 绑定。不混用二进制身份。
- `readiness-tests.log.gz`、`gates.json`：15 项发布台账回归通过；结构检查退出 0，require-ready 按未就绪退出 1。`qualification-unchanged.json` 保留 102 行状态边界。
- `red.log.gz`：新模块未实现时的 RED；后续定向日志保留实际结果。
- `independent-review.json`：新上下文只读综合审查，无实质问题。真实全片解码结果在复审后完成，由主代理逐条核验，未冒充审查者已检查的证据。

复现主要命令（路径为实际运行所在宿主，可调整；trace 必须为新路径）：

```sh
YL_RUN_DECODE_PROBE=1 "$venv/bin/python" -B -m unittest discover -s tool/dolby_reference -p 'test_*.py' -v
python3 -B tool/dolby_reference/probes/build_stream_inspector.py --probes "$pinned_probes" --output "$new_inspector_build"
python3 -B tool/dolby_reference/probes/build_decode_probe.py --output "$new_decoder_build"
python3 -B tool/dolby_reference/decoded_alignment.py --media "$media" --sha256 "$media_sha256" \
  --inspector "$new_inspector_build/target/release/yl-dovi-stream-inspector" \
  --decoder "$new_decoder_build/yl-decode-layers" --metadata --trace "$new_trace"
```

生成合成夹具使用相同 CARGO_HOME/RUSTC/CARGO_TARGET_DIR，`cargo build --locked --offline --release --manifest-path "$new_inspector_build/inspector/Cargo.toml" --example cm_state_fixture`；生成器 stdout 写入 synthetic.rpus，探针 `synthetic.rpus --dm-color` 输出 synthetic-parsed.jsonl。`verify_synthetic.py <repo> <evidence-working-dir>` 复核状态，`verify_decoded.py <evidence-working-dir>` 复核全片；先将 `.jsonl.gz` 解压到新的临时目录，不覆盖归档。

实际临时根 `/private/tmp/yl-p07-cm-state`，媒体仍只读使用主仓库缓存；源媒体哈希见两份 decoded JSON。没有提交原媒体或构建库。固定 FFmpeg 研究来源见接口文档，不改变产品依赖。

完整有效 CM/trim/目标映射、真实压缩视频、压缩 CM4/L254 上游缺口、独立目标/容差及物理 DV 仍开放。未变播放器矩阵复用 2026-10-28 同源码证据，未重新运行 iOS/设备验收，也未覆盖历史失败。不推送、不发布。
