# 混合 MP4 字幕：初始样本表与后续分片

按“继续下一项”扩展完整单资源MP4发现：同一tx3g/wvtt/stpp轨道可同时包含moov中的普通
stbl样本与后续moof样本。沿用 `discoverEmbeddedSubtitles()`、`mp4:<Track ID>` 和既有
SRT归一化/ WebVTT / TTML目录与renderer，不增加公开API、原生能力、依赖或网络入口。
此前fMP4契约中“初始化字幕样本必须为空”与hybrid拒绝由本项取代。

## 接续规则

- 初始sample按原stsc/stsz/stts/ctts/chunk描述读取；后续sample沿用trex/tfhd/tfdt/trun。
  初始化可空或非空，各轨数量/时长可以不同。只有初始sample而尚无moof也可形成目录。
- 每轨初始decode结束点取stts时长之和。后续tfdt不得小于该值；不使用ctts后的presentation
  时间、edit裁切后的可见终点或最后发布cue推算。空sample及被编辑裁掉的sample仍推进decode。
  合法composition重叠可以保留，允许decode空隙，不能用时间重置覆盖先前内容。
- 初始与后续使用同一track状态、sample ordinal、TTML原始字节计费与packet列表。TTML按
  轨道composition时间裁切sample，再统一进行既有简单edit映射；样式/region身份不在分片重置。
  stsc与tfhd可以选不同同codec描述，默认样式随当前description变更，不继承上一sample样式。
- 分片模式下汇总全部字幕sample的byte extents，包括所有轨道初始表与所有分片；必须位于
  顶层mdat payload，发布前拒绝任何字幕sample字节重叠。非分片文件原验证范围不变；不解析
  音视频样本表，也不宣称验证字幕与音视频byte alias。初始部分已有的同轨chunk检查保留。
- 样本20000、cue10000、retained run20000、payload4MiB、metadata/read64MiB、结构box/
  7天时间等上限跨初始和后续共用。TTML空/裁切文档仍计原始字节；既有目录限额另行验证。

## 生命周期与网络

完整扫描和目录构建成功后一次发布。初始部分成功不代表可以提前替换目录；后续网络/解析/
版本失败保留旧目录和选择。切轨/off/seek/偏移/首帧门禁与取消沿用现有owner。

HTTP(S)复用原managed Range reader：单段206、强ETag/固定总长/最终URI、If-Match，
共享retry/redirect/credentials/逐跳connect与空闲read超时，16KiB窗口/128缓存、4096尝试/
64MiB响应预算；无200全量回退、额外资源访问或新总deadline。只保证字幕扫描版本固定，
不保证native视频来源版本相同。长播放与弱网ABR工作未修改。

## 明确边界

这是完整MP4文件格式接续，不是MSE空初始化段符合性声明。仍需要现有支持的mvex/trex、
moov先于moof、显式tfdt、受支持的寻址/codec/样式/edit；不接入独立init/mediaURL、
HLS/DASH字幕清单、直播增长/跨Period身份、加密/外部dref或高级字幕效果。格式过大/复杂
可按预算拒绝；无进程RSS、native/device/HDR/DRM/PD03或整个P02完成声明。

验证包含自有三codec混合样本、真实文件/HTTP/Flutter，以及hostFFmpeg8.0.1独立混合tx3g
文件。独立夹具的初始stsz包含可见文本、后续moof包含第二条文本；按ffprobe实际容器时标
断言0–3.123s与3.123–4.567s，不把输入SRT的2.5s终点当作容器事实。视频backend为fake，
独立生产器仅覆盖tx3g，不作所有wvtt/stpp生产器互通宣称。
