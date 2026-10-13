# Matroska 内嵌 PGS 位图字幕

P02 的下一切片通过 `discoverEmbeddedSubtitles()` 接入本地文件与 managed HTTP(S)
Matroska `S_HDMV/PGS`。按TrackUID选择，复用现有PGS解码/Flutter位图overlay和字幕owner；
`enableTextSubtitles` 保留历史名称。公开API注释同时补齐WebM及位图范围，无新公开类型、
原生制品、依赖、视频解码或网络reader变更。

## 容器与显示语义

- 原始PGS二进制包独立保存，不经过UTF8/文本markup。Block可含一个或多个完整的PGS
  type/length/body段；一个PCS到END显示集可以分布在多个Block中。支持独立FFmpeg自动
  frame-merge封装；不接受在Block边界截断的单个段、缺END或无PCS的段。
- PCS所在Block的时间按TimestampScale/CodecDelay转换到微秒，直接送入PGS状态机，
  不伪造SUP头、不经90kHz/32bit回绕而丢失精度。PCS时间必须非递减；其他段不改写PCS时间。
- 有BlockDuration则约束当前显示集；没有时可用Track DefaultDuration，否则延续到下一
  已完成显示集（最终可见帧到7天/session结束）。分段显示集取所有显式结束点的最早值，
  并受下一PCS时间裁切；结束点不得早于或等于PCS时间。相同PCS时间后者替换前者。
- 调色板更新、窗口、RLE对象/碎片、裁剪、forced位与空PCS清屏沿用已冻结PGS子集。
  显示时限只限制可见区间，不销毁PGS缓存；后续合法显示集可重用对象/调色板。
- PGS不使用非空CodecPrivate；压缩/加密/lacing/BlockAdditions/CodecState仍拒绝。
  WebM、MP4 PGS不接入；原文本codec和WebM准入边界保持。

## 预算、网络和生命周期

原始PGS Block≤256KiB，所有启用字幕轨payload合计≤4MiB，PGS Block总数≤50000，文档
段数≤50000、显示集/cue≤10000；沿用EBML结构/读取及七天时间上限。超大Block在读取前
拒绝。PGS原始包字节进入共享目录4MiB计费。发现时从64MiB展开RGBA预算中扣除保留外挂
目录，每条内嵌轨道在分配前拿到剩余额度；外挂替换同样扣除已保留内嵌位图。旧目录与
待发布目录有独立有界所有权，无RSS上限声明。对象/索引缓存与GPU图片队列仍用原PGS限制。

网络复用单段206、强ETag/长度/最终URI、If-Match、managed重试/重定向/凭据剥离和超时/
取消；目录完整构建后原子发布。失败保留旧目录，不替视频决定PD-03策略。混合文本/PGS
切换、off、正负offset、seek与源替换沿用原owner，迟到HTTP响应和图片不能重新发布。

## 验证边界

自有单段/合并包、精确微秒/显式时长、预算/错误测试；真实文件/HTTP；公开Flutter会话
验证像素颜色/位置、调色板变化、文本/位图切换、清屏和图片释放。独立hostFFmpeg8.0.1
将自有SUP封装为MKV，实际输出PCS时间0/1/2s（输入SUP为1/2/3s），按容器时间断言。
对剩余位图预算做隔离故意回归，确认“外挂先加载”和“两条内嵌”用例能检出超限接纳。

不是native/实机或完整Blu-ray图形认证；复杂PGS、内嵌VobSub、HDR/DRM/外接显示、直播/
清单/跨Period、PD-03和整个P02继续开放。长播放与弱网ABR未涉及。
参考：[Matroska PGS mapping §6.5](https://datatracker.ietf.org/doc/html/draft-ietf-cellar-codec-17#section-6.5)
及[已有PGS子集](2026-10-11-subtitle-pgs.md)。
