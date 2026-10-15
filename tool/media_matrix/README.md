# P03 格式基线

当前目录有22份原创短片/损坏夹具，共覆盖8类容器、4类目标视频和8类音频；目录在 `packages/yl_player/example/assets/test_media/format_matrix/`。每个样本列出Android/iOS/macOS及file/http调查行，三端调查行与公开路径证据分开记录；完整输出验收仍开放。MPEG-2/MP3仅用于合理的MPEG-PS容器探测，不新增视频编码支持承诺。Profile/位深、声道、seek期望独立记录；`expected_seekable`表示测试目标，不宣称媒体自带索引。

生成：`python3 -B tool/media_matrix/generate.py`。需要FFmpeg8.0.1及记录的编码器，生成命令/版本、独立ffprobe结果与SHA256SUMS随样本提交。颜色标记每秒red/lime/blue/white；音频每秒440/660/880/1100Hz，每声道加55Hz，5.1的LFE改用60/70/80/90Hz。图形与声音均为本项目原创生成，不含外来影视材料。编码器/封装器的随机标识可能导致重新生成的字节哈希不同，必须重新probe、验证并记录实际哈希，不以命令相同推断字节一致。

```sh
python3 -B -m unittest discover -s tool/media_matrix -p 'test_*.py'
python3 -B tool/media_matrix/catalog.py
python3 -B tool/media_matrix/verify_samples.py
```

前两项进入 `tool/check_foundation.sh`；后者用宿主FFmpeg独立解码，确认16份正常素材的颜色与声道音调、拒绝32字节截断MP4，只证明夹具有效。既不替代播放器像素对照/物理声音，也不更换生产FFmpeg制品。无索引Matroska使用`-live 1`生成，本次文件不含Cues元素ID；该行的seek仍需实际观察。

从 `packages/yl_player/example` 运行真实公开路径：

```sh
flutter test integration_test/format_matrix_test.dart -d macos
# 严格支持门槛：已有缺口会让此命令失败，不吞掉失败行。
flutter test integration_test/format_matrix_test.dart -d macos --dart-define=YL_FORMAT_REQUIRE_SUPPORT=true
```

每个夹具测试file/http及同字节错误扩展名；MP4正常/截断样本另有无扩展名本地、错误扩展名HTTP，共55项；自动探测，不显式提示格式。HTTP为受控本机Range服务器，不能推出广域网性能。公共首帧、position推进、音轨选中、seek后推进、结束、释放分别断言；没有独立audio-clock API，记录null，不把timeline或“有音轨”当音频输出/同步已验收。像素和声音标记在播放器输出上仍待验证。

`baseline-macos.json`是当前macOS27/Apple M1的逐项回归预期，记录具体outcome/stage/code/category/scope及里程碑。默认模式验证现状是否变化；已知正常媒体失败仍在`YL_FORMAT_ROW`中写failed/timeout，不能把“51项基线匹配”写成“51条格式支持”。正常素材严格模式要求全部播放成功；损坏素材要求失败、source/container分类、session范围且没有首帧。其他平台没有现状基线，默认按严格门槛运行，不能套macOS预期。支持扩展后应重新实测再更新基线。

首轮历史macOS记录在 `macos-observations.json`（51项）：17个正常路径完成公开生命周期、31个正常路径存在缺口、3个损坏输入拒绝。全部仍缺输出像素/声音/同步及最低系统验证。Android/iOS未运行，不能从同一Swift源码推出它们通过。详见 [P03报告](../../docs/superpowers/reports/2026-09-26-remaining-03-formats-decoding.md)。

MP4格式传递修复后的记录在 `macos-mp4-mime-observations.json`。新增4项变体不改写原始51项历史证据；55项当前预期见资产中的baseline。macOS14/iOS17起使用公开MIME指定接口保留已探测/显式MP4格式；本轮仅实跑Apple M1/macOS27，旧系统仍保留原行为，未声称iOS实测或任意已知错误扩展名均可播放。

HEVC跳转修复记录见`macos-hevc-seek-observations.json`，保留前两轮历史观测。两个HEVC样本现执行前向2秒及反向1.25秒跳转；`sh tool/media_matrix/check_hevc_random_access.sh`验证随机访问状态、连续CRA、RADL、1/2/4字节NAL前缀和损坏边界，已接入macOS基础检查。此测试不证明输出像素、声音或跨平台支持。

FLV点播修复记录见`macos-flv-vod-observations.json`。FLV三路径增加点播时长/seekability断言和前向2秒、反向1.25秒跳转；`flv_intent_test.dart`独立验证无Range服务的三种意图，已接入macOS原生脚本；`macos_http_flv_playback_test.dart`保留原直播重连回归。HTTP-FLV点播须显式声明onDemand，automatic继续直播语义。

FLAC修复记录见`macos-flac-observations.json`。AVC/FLAC三路径现执行前向2秒/反向1.25秒seek；原生`YlMacosAudioTests`另以原创16位mono/24位stereo整数斜坡独立核对PCM。PCM证据与公开生命周期分开，不声称物理输出或音画同步通过。

Opus SILK/hybrid扩展新增两份原创mono素材，当前目录20份/64条公开路径。`mkv-avc-opus-silk`为60ms SILK；`mkv-avc-opus-hybrid`实际先20包hybrid后181包CELT，包含真实模式切换。两份素材的file/http/renamed-file均经严格支持测试，通过2s/1.25s/0 seek及结束。生产桥接使用固定开源libopus1.6.1，源码/制品的独立参考PCM检查覆盖mono/stereo，仍以50dB为门槛。物理输出和跨平台验收仍未完成；新证据见`macos-opus-modes-observations.json`，历史观测不改写。

Vorbis切片新增零CodecDelay的原创AVC/Vorbis素材，目录现有21行/67条公开路径。
`generate.py`现在要求`YL_TEST_VORBIS_REFERENCE`指向通过
`packages/yl_player_apple/tool/apple_ffmpeg/build_vorbis_reference.sh`生成的install目录；
自有Xiph encoder按真实采样率/声道输出，避免native FFmpeg encoder写入本轮未支持的CodecDelay。
原有20份素材保持不变；初始native编码夹具另保留为`mkv-avc-vorbis-codec-delay.mkv`，
用于明确拒绝1024采样CodecDelay，不计支持行。混合AAC/Vorbis仅用于切轨/策略。
物理输出和跨平台验收仍未完成，详见`macos-vorbis-observations.json`和P03报告。

VP9切片保留全部21份媒体，仍为67条公开路径。`webm-vp9-opus`增加
2s/1.25s/0跳转和每次重建后的hardware断言。`webm-vp9-vorbis`保留原始
非零CodecDelay样本，继续记录明确音频支持缺口。`check_vp9_headers.sh`使用
从原WebM直接复制的96帧IVF，不依赖宿主FFmpeg；来源、命令及哈希见
`fixtures/vp9-profile0.json`。硬件提示探测与真实session硬件证据分别记录；
最终观测见`macos-vp9-observations.json`，物理像素/声音/同步仍未验收。


P03 完成工程切片增加 `observations.py`：固定 run/build/media 身份和计划行数，
分开统计 required、diagnostic 与截断负控；像素、原生 PCM 和音频时钟必须
属于同一运行才能形成完整输出验收。公开 `YL_FORMAT_ROW` 当前不包含同次
原生 PCM，且构建身份未嵌入时明确为 `unrecorded`，不得通过跨 run 拼接
把它升级为完整验收。实际 Android/macOS/iOS 观测与历史失败见 P03 执行报告。

公开矩阵默认观察真实像素：Android texture 采用 RGB 容差40；Apple 屏幕
截图受宿主 ICC 影响，只辨认四段红/绿/蓝/白身份（主通道至少180、领先其他
通道至少100；白色各通道至少220且差值至多35），原生测试独立核对精确解码
像素。每段及2s/1.25s/0 seek 后都等待实际目标图像，失败保存截图，
宿主缩放变化使该 run 失败。此观察不证明物理屏幕色准或音画同步。

`av1-hardware-control.mkv` 是硬解错误测试专用的视频独立控制片，不加入
格式支持分母。从现有原创 AV1/Opus 片无损复制视频，96个压缩包 SHA 均相同；
来源、工具版本、逐包哈希在 `tool/decoder_probe/fixtures/av1-hardware-control.json`。
它避免既有 Opus 硬解策略先行拒绝，单独观察真实视频 `decoder.unavailable`。

若宿主截图慢于一秒标记窗口，可另起 run 加
`--dart-define=YL_FORMAT_SLOW_CAPTURE=true`，以0.25×运行并在每行记录
`playbackRate`。它是独立的观测控制，不替换、抹去或计作1×失败行的同条件通过。
