# MP4 内嵌 TTML（stpp）切片契约

继续已授权 P02 的本地/HTTP(S) MP4 字幕发现、Track ID选择与实际渲染；网络执行 managed 策略，验证后本地提交。复用已存在的非分片 MP4 demux、TTML parser/region overlay 和字幕 owner。不触碰并行长播放/弱网ABR，不关闭整个 P02。

## 接纳与时间

- 在 tx3g/wvtt 路径上接纳 `stpp`，公开格式使用既有 `ttml`，身份为 `mp4:<Track ID>`，语言/名称使用 mdhd/hdlr。不同 codec 可分轨共存；一个轨的样本描述不得混用 codec。没有公开 API、原生桥或依赖变更。
- sample entry 的8字节头后读取3个NUL结尾UTF8字符串：namespace 必须恰为 `http://www.w3.org/ns/ttml`，schema_location 仅保留格式校验、不访问网络，auxiliary_mime_types 必须为空。每字段≤4096字节，拒绝控制字符、缺终止符；仅可附加一个12字节payload的btrt。加密、未知entry/辅助资源、subs子样本表明确拒绝。
- 每个 sample 是独立UTF8 TTML XML文档；允许BOM，沿用严格XML、DTD/外部实体禁用与命名空间校验。空文档表示间隙；不使用零字节sample。非空可见文档的零时长sample拒绝。编辑外文档也须通过解析，不能借裁切隐藏损坏输入。
- 采用 ISO/IEC14496-30:2018/Amd1:2022 的澄清：TTML文档时间在轨道composition时间轴上；不加sample起点。解析父级begin/end/dur后，与stts/ctts定义的sample区间相交，再应用既有简单rate1编辑和空白延迟。整数比例先合并后舍入微秒，区间为[start,end)。不启用旧版presentation时间猜测。
- 有界sample为未指定end的段落提供终止边界；外置TTML仍要求可确定有限end。每文档独立ID/style/region作用域；相邻sample重复文档不按ID去重，每个sample的region身份隔离，重叠sample中同名region可有不同几何。

## 样式、目录与网络

- 复用现有TTML子集：body/div/p/span/br、继承样式/引用、粗斜体/下划线/颜色、百分比region与displayAlign/textAlign。已解码的textRuns和region直接进入目录，文字中的标签/箭头不再解释为SRT/HTML。
- 未扩展TTML语义：cell/pixel字号、字体资源、图像/SMPTE/IMSC图片、动画、timed span、复杂profile、非media时间基等仍显式拒绝。没有任意合法stpp兼容性或完整TTML/IMSC承诺。
- 每次sample读取≤256KiB，XML深度≤32/事件≤50000/属性与样式限制沿用现有parser；单cue≤16384码元、每文档及目录≤10000cue、保留runs≤20000、活动cue≤64、时间≤7天。沿用MP4样本/轨道/读取预算及所有字幕sample累计≤4MiB。目录输入计费取原始TTML字节与归一化载荷二者较大，空文档和未发布内容也计入原始字节，与外挂字幕共享4MiB总预算。
- network reader未修改：单段206、稳定强ETag/总长/URI、If-Match、16KiB窗口/128缓存、4096次HTTP尝试/64MiB响应体、managed connect/read超时、共享retry/redirect及跨源敏感头剥离。schema、字体、XML资源不发起额外请求；没有200整文件回退。
- 当前会话显式discover，失败原子保留旧目录/选择/视频状态；切轨/off/seek/偏移/首帧门禁沿用owner，换源/stop/dispose/外置目录操作隔离迟到扫描。fMP4/HLS/DASH/native回调仍不支持。

## 验证边界与格式来源

测试使用owned手写BMFF/XML、实际文件、真实loopbackHTTP和Flutter文字/region几何；视频backend为fake。host FFmpeg8.0.1另封装owned黑视频+SRT为stpp，其cellResolution/字号/字体等超出既有TTML子集，作为明确拒绝的独立负向样本，不能当作正向互通性证据。没有原生构建、设备/HDR/DRM/PD-03/长播放/弱网ABR验收。

以下为格式语义核对，未复制实现代码：

- [ISO/IEC14496-30:2018/Amd1:2022](https://www.standards.iteh.ai/catalog/standards/iso/c559486e-2191-4975-ad44-9f061b600281/iso-iec-14496-30-2018-amd-1-2022)：修订文的composition时间和sample裁切。
- [Shaka MP4 TTML parser](https://shaka-project.github.io/shaka-player/docs/api/lib_text_mp4_ttml_parser.js.html)：每sample XML与各自时间窗口；仅作对照，本项不实现其分片/图像支持。
- [GPAC subtitling](https://github.com/gpac/gpac/wiki/Subtitling-with-GPAC)：stpp XML subtitle sample entry与namespace。
