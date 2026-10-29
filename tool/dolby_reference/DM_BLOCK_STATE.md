# CM 扩展块传递状态及解码帧绑定

`stream_inventory.py --dm-blocks` 输出 schema 5，隐含 `--dm-color` 和 `--mapping`。固定探针仍调用 `--dm-color`，无库补丁。原 schema 1–4 入口保持原样。新记录 `dm_block_state.blocks` 保存 CM 版本、level、target、static 标志、来源包、原始 payload 及其 SHA-256；`blocks_sha256` 绑定按 CM/level/target 规范排序的内容，不含来源包，因此相同内容在不同包重申时内容哈希相同。

本工具只恢复**块传递状态**，不会执行 trim、推导目标显示器或计算像素。分类依据固定 [FFmpeg n8.0.1 dovi_rpu.h](https://github.com/FFmpeg/FFmpeg/blob/n8.0.1/libavcodec/dovi_rpu.h) `ff_dovi_rpu_extension_is_static`；读取文件 SHA-256 `cc91857f1913e2c1d47989a77ac2eb18bec9a97b94ab386a868b8ecaae20745a`。状态更新依据同版本 [dovi_rpudec.c](https://github.com/FFmpeg/FFmpeg/blob/n8.0.1/libavcodec/dovi_rpudec.c) `parse_ext_blocks` 及 703–709 行。库仅作研究依据，不更改播放器版本。

| 类别 | 本子集 level | 行为 |
| --- | --- | --- |
| 静态 | 6、10、254、255 | 完整 DM 替换整组；后续压缩 DM 继承，保留原来源包 |
| 动态 | 1、2、3、4、5、8、9、11 | 每包替换，缺失即不在本包有效块列表内；不从相邻显示帧继承 |
| 未支持 | 32（保留静态）、253、其他未知 level | 拒绝，不能猜测其布局或继承类别 |

完整记录同时清空旧静态和动态块；压缩记录不能携带静态块。继承必须满足已有颜色头契约：同 ID、同配置、有完整前序状态、新调用无历史、明确序列头及 DM、无未知剩余位。只接受固定 libdovi 的已知字段、长度和数量；类型不符、CM 版本内 level 错位、重复单例或重复 L2 target_max_pq/L8/L10 target_display_index、超过块数量上限均退出 2。L8 的 10/12/13/19/25 字节、L9 的 1/17 字节、L10 的 5/21 字节保留各自实际字段集合，不为缺字段补零。target 只作块身份，不表示它已匹配独立目标或执行目标映射。

**固定库的压缩 CM4 缺口仍在。** `CmV40DmData::validate` 要求非空 CM4 容器有一个 L254，而 L254 在压缩 DM 中属于禁止携带的静态块。因此本子集可保留前序完整 CM4 的静态块，并接受后续省略 CM4 容器的压缩记录；携带 CM4 动态块但无 L254 的压缩记录不能由当前固定库验证，携带 L254 又会被本状态器拒绝。本轮不修改该上游限制，也不宣称完整压缩 CM4 支持。

`decoded_alignment.py --metadata` 在原始媒体哈希校验、包编号、PTS/POC、BL/EL 完整覆盖核验内，输出 schema 2，把 mapping 引用、颜色头和 CM 块来源随包绑定到实际软件解码帧。`metadata_inventory_trace_sha256` 绑定中间盘点，最终 `trace_sha256` 绑定帧像素哈希和全部元数据来源；默认无此参数时仍为旧 schema 1。

```sh
python3 -B tool/dolby_reference/stream_inventory.py \
  --media "$media" --sha256 "$sha256" --inspector "$inspector" \
  --dm-blocks --layers --trace "$new_inventory_trace"
python3 -B tool/dolby_reference/decoded_alignment.py \
  --media "$media" --sha256 "$sha256" --inspector "$inspector" \
  --decoder "$decoder" --metadata --trace "$new_decoded_trace"
```

有限输入和进程上界沿用盘点/解码工具；每 CM 容器最多 16 块，单例及重复 target 另有限制。输入、状态与解码核验失败在写 trace 前返回，已有路径拒绝覆盖。解码工具支持原有 P5/P7 媒体范围；合成 P8 RPU 序列只测试解析与继承，不伪装视频解码或真实压缩样本。

`dm_block_state_resolved=true` / `dm_color_state_resolved=true` / `mapping_reference_ids_resolved=true` 均是有限子集标记；`effective_metadata_resolved=false`、`mapping_quality=external_missing`、`native_dv_signal=external_missing` 保持。真实压缩视频、跨 ID/缺头/默认 DM、完整 CM/trim/NLQ/重采样/目标映射、独立目标/容差和物理 DV 仍未完成。
