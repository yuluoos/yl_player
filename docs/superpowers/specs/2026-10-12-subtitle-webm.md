# WebM 内嵌 WebVTT 字幕

P02 的下一切片在现有字幕发现入口接受 WebM；本地文件和 managed HTTP(S) 使用同一
有界 EBML reader、TrackUID 目录、WebVTT 文档与 Flutter overlay。无公开 API、原生
能力、依赖或视频路由变更。先前 Matroska WebVTT 契约中的 WebM DocType 排除由本项取代。

## 格式与身份

- `YlMediaFormat.automatic` 按字节识别 EBML，再读取 DocType；不依赖文件扩展名或URL。
  显式 `webm` 只接受 DocType `webm`；显式 `matroska` 只接受 `matroska`。声明不符拒绝。
- WebM 的启用字幕轨只接纳 TrackType17 的 `D_WEBVTT/SUBTITLES` / `D_WEBVTT/CAPTIONS`。
  其他非字幕轨（含 TrackType33 descriptions/metadata）跳过，不能误当画面字幕。
  S_TEXT/UTF8、ASS、SSA、S_TEXT/WEBVTT 等 Matroska 专属字幕在 WebM 中不放宽接纳。
- 沿用 `mkv:<TrackUID>` 稳定身份；它代表 EBML 轨道命名空间，不是扩展名。相同语言不同
  forced/main角色和重排仍按 UID 选择；不新增跨资源或跨Period身份承诺。
- D_WEBVTT Block 的前两行为 identifier/settings，后面为正文。显式 BlockDuration、
  UTF8/字段验证、现有样式/水平位置子集和计费沿用 Matroska WebVTT。无非空CodecPrivate、
  lacing、加密、压缩、其他addition或高级WebVTT效果。header的版本/结构预算仍适用。

## 网络、资源与生命周期

复用 managed Range 的单段206、强ETag/长度/最终URI、If-Match、重试/重定向/凭据剥离、
超时和取消，保留请求/字节/窗口缓存限制；无200全量回退。HTTP live/DRM 仍在请求前拒绝。
沿用字幕原始输入4MiB、cue10000/同时64条、正文/字段长度、结构/读取/时间限制，媒体
payload跳过。发现成功才原子更新目录；失败保留旧选择，切轨/off/正负offset/seek立即清屏，
取消后迟到响应不发布。字幕扫描版本固定不保证与native视频表示一致，也不新增总deadline。

## 证据与限制

真实文件和HTTP覆盖 automatic/webm声明、错误声明、内容识别、两类字幕轨、身份、错误
和managed策略；Flutter fake视频backend验证粗体、25%水平位置、main/forced切轨与生命周期。
自有黑帧VP9+WebVTT由host FFmpeg8.0.1独立封装，按ffprobe的0.503–1.707s验证字幕。
本功能扫描字幕，不做完整WebM音视频符合性验证，也不改变视频解码支持；实机/HDR/DRM/
外接显示、高级字幕、直播/清单/跨Period、PD-03和整个P02仍开放。长播放与弱网ABR不涉及。

映射依据：[WebM WebVTT Guidelines](https://www.webmproject.org/docs/container/#webvtt-guidelines)。
