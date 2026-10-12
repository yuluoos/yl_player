# fMP4 内嵌 tx3g（mov_text）延续契约

本项按“继续下一项”补齐已声明的 fragmented tx3g 缺口；继承 [fMP4 容器契约](2026-10-11-subtitle-fmp4.md)
和 [MP4 tx3g 子集](2026-10-11-subtitle-mp4.md)。同一完整本地文件或稳定 HTTP(S) 资源中的
moov/mvex 初始化信息及 moof/mdat 可发现 tx3g，按 `mp4:<Track ID>` 选择并实际渲染。
字幕目录格式仍为 `srt`（归一化文本类型），编码仍是 tx3g，文字和样式直接传递，不再解析为标记。

唯一生产行为扩展是取消分片模式对 tx3g 的格式拒绝；保留初始化字幕样本必须为空的条件。
复用 trex/tfhd/trun 的样本大小/时长/description 覆盖、tfdt/CTO、byte extent 验证与简单
edit 映射（包括分片 duration=0 播放编辑）；解码器与 managed 网络 reader 均不修改。

UTF8、BOM UTF16、Unicode scalar 样式范围、默认样式和 styl、粗斜体/下划线/颜色/字号/
本地字体回退、对齐、文本底色及整轨 forced 元数据保持原 tx3g 子集。不同 sample description
可以改变默认样式，不能改变 codec；默认 forced 身份按所有描述一致性确定，不自动启用。
空文本不生成 cue，零时长空终端sample允许，非空零时长拒绝。全部跨片预算与取消/原子发布规则
沿用 fMP4/MP4 契约；关闭、换轨、seek、正负偏移和首帧门禁由现有 owner 管理。

仍拒绝 hybrid 初始化字幕样本、独立初始化/segment URL、字幕清单/直播增量、加密/外部dref、
高级 tx3g tbox/karaoke/滚动/部分forced等。网络固定版本只保证本次字幕扫描，不证明native视频
请求版本相同。没有新增公开API/Pigeon、依赖或native能力；不触碰长播放/弱网ABR。

验证采用 owned BMFF 字段夹具、真实文件/HTTP/Flutter，以及 host FFmpeg8.0.1 独立封装的
黑色视频与自有SRT（见[夹具说明](../../../packages/yl_player/test/fixtures/fmp4-tx3g-owned.md)）。
独立样本以ffprobe所见**封装后的**sample时间为准，不能将FFmpeg输入SRT时间当作最终容器时间；
此样本首条非空sample结束于3.123s而输入文本为2.5s。测试证明读取容器时间正确，没有声称修正muxer。
样本足以验证一条生产器路径，不是任意合法fMP4互通/字体像素等价或三端真机验收。
整个P02、native/HDR/DRM/外接设备和PD-03仍开放。

## Hybrid MP4 extension (2026-10-12)

The earlier empty-initial-subtitle-table requirement is superseded by the
[hybrid MP4 contract](2026-10-12-subtitle-hybrid-mp4.md). Initial stbl samples and
later moof samples now share track state, decode continuity, subtitle extents
and budgets in one complete resource; existing codecs, managed loading and
rendering subsets remain in force.
