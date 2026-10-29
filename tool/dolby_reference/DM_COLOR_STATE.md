# DM 颜色头状态（离线研究）

`stream_inventory.py --dm-color` 使用固定版 libdovi 的原始 RPU 字段，输出 schema 4；该选项隐含 `--mapping`，可与 `--layers` 同用。默认及 `--mapping` 仍输出原有 schema 1–3。探针只接受一种输出模式，因此 Python 只向它传递 `--dm-color`。

每个 JSONL 记录包含原始 `rpu_header`、`mapping_reference` 和 `dm_color_state`。颜色状态保存整数原值：YCC→RGB 矩阵/偏移、RGB→LMS 矩阵、EOTF 参数、信号位深/色彩空间/色度格式/范围、源 PQ 上下限与对角线；**不作矩阵缩放、单位换算或像素运算**。`color_sha256` 对颜色字段的规范 JSON 绑定，`rpu_header_sha256` 对原始头绑定，`color_source_packet_index` 指向完整颜色字段的来源包；外层原始 RPU、媒体和工具哈希保持可追溯。

解析先按连续 `packet_index` 的解码顺序建立状态，再按整数 PTS 排序输出。非压缩 DM 建立新状态；压缩 DM 的字段零只是固定解析库的占位值，必须取已建立的颜色状态。每次调用都是新 epoch，至多 32768 包、单条解析记录 1 MiB，其他媒体/进程上界沿用 stream inventory。输出 trace 仅全部成功后以排他方式创建。

保守支持边界：

- P5/P7/P8 的完整 DM 颜色头；压缩颜色仅接受 P8、compression=1。
- 同条 affected/current ID 均为 0–15 且相等；压缩还要求与最近完整状态同 ID、同序列配置。不会回查旧 ID 槽，也不跨配置继承。
- 每包必须有明确序列头、DM，且无未解析剩余位；只有固定 libdovi 的已知字段布局。
- 缺历史、缺 DM、未知压缩/头布局、跨 ID、不一致 mapping 标志、越界/非整数颜色、压缩字段中非零值均退出 2。合法但超出本子集的输入也可能被拒绝，不等于源媒体无效。

依据：固定 [libdovi 614c816 的 VdrDmData](https://github.com/quietvoid/dovi_tool/blob/614c816b6446dcd1dbaf433403d499a6026fbb5a/dolby_vision/src/rpu/vdr_dm_data.rs) 明确将压缩时未读的颜色字段置为默认值；[FFmpeg n8.0.1 dovi_rpudec.c](https://github.com/FFmpeg/FFmpeg/blob/n8.0.1/libavcodec/dovi_rpudec.c) 648–701 行对 affected/current ID 不一致拒绝，并在压缩记录中保留颜色字段。本实现进一步拒绝未建立状态及跨配置/ID 继承，不推断未说明的语义。核对的 FFmpeg 文件 SHA-256 为 `77f2856e6f2bf75b6b8be24fda8ffefce3de96ed61bd8d9f8998c54819cdcf8b`；它仅为研究依据，不改变播放器 FFmpeg 版本。

`dm_color_state_resolved=true` 只表示上述颜色子集。`effective_metadata_resolved=false`、`decoded_frame_alignment_verified=false`、`mapping_quality=external_missing`、`native_dv_signal=external_missing` 保持不变。CM 扩展/trim 的静态继承、目标显示管理、完整映射和跨序列解码帧对齐仍不在此工具内；生产支持没有扩大。两份缓存公开 P5/FEL 素材均没有压缩 DM，真实压缩流覆盖继续缺失；Rust 生成的压缩 RPU 仅用于解析契约测试。

```sh
python3 -B tool/dolby_reference/probes/build_stream_inspector.py \
  --probes "$p07_probes" --output "$new_build_dir"
python3 -B tool/dolby_reference/stream_inventory.py \
  --media "$media" --sha256 "$media_sha256" \
  --inspector "$new_build_dir/target/release/yl-dovi-stream-inspector" \
  --dm-color --trace "$new_trace"
```

后续可选 `--dm-blocks` 在颜色头子集之外提供已知 CM 块传递状态，并可绑定到解码帧；`--dm-color` 本身的范围保持不变。见 [DM_BLOCK_STATE.md](DM_BLOCK_STATE.md)。
