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
`packages/yl_player_media_core/tool/apple_ffmpeg/build_vorbis_reference.sh`生成的install目录；
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


P03 PCM boundary/switch control is generated explicitly with
`python3 tool/media_matrix/prepare_pcm_alignment.py`. It packet-copies the four
owned AC3 5.1/EAC3/DTS/FLAC tracks, preserving the catalog fixtures, and pins
host FFmpeg frame timestamps and unshifted Float32 reference windows. Native
tests compare first/last 4096 frames, every packet's PTS/frame count, and the
2.5-second cold track-switch output. The Dolby files start at -5 ms and decode
192000 raw frames; programme-zero clipping retains 191760 frames. DTS/FLAC
retain 192000. These are the encoded files' boundaries, not a claim that their
lossy encoder preserved every original source sample.

`python3 tool/media_matrix/check_dolby_bridge.py PATH/TO/YlFFmpegBridge.framework/YlFFmpegBridge`
checks actual Dolby ABI PCM, capacity rejection before consumption, reset and
failure poisoning. Host references share FFmpeg decoder ancestry with Dolby,
DTS and Android; CoreAudio FLAC remains an independent implementation. This
separate-build regression proof does not replace independent decoder or physical
speaker/A/V qualification. Neither script changes production admission profiles.

### Apple 公开 Flutter 暂停快照

`run_bound_flutter_apple.py` 在一次构建后冻结整个 opt-in Debug app，再经公开
controller/session/view 运行六控制、完成和三次 seek。`bound_av.py` 要求同一
run/build/session 的 PCM、实际消费位置与显示层像素，以及 Flutter 框架最终成功。
`--negative-identity` 和 `--negative-framework` 分别验证播放前身份拒绝和
原始记录通过后框架失败仍拒绝。不要在运行期间重建 app。

Apple 的 `displayedPixelBuffer()` 要求渲染器实际速率为零。公开 pause 的完成
不代表该条件成立：无 `controlTimebase` 的显示层仍使用速率为一的主机时钟。
seek 后先等待实际音频消费时钟就绪再公开暂停，避免将尚未启动的输出冻结在
无效时钟状态；该就绪观察只决定能否暂停，配对证据仍单独读取之后的暂停时钟。
显式 `DEBUG && YL_BOUND_AV` 采集器等待实际显示层就绪后冻结同一层，读回为空时
保持音频暂停；空读回时归还显示时钟，让已排队画面在下一次轮询前完成呈现，
随后再次冻结。成功后恢复时钟再由公开 API 继续播放。已有停止时基按对象身份
归还；原来隐式的主机时钟以显式速率一时基保留到该采集表面释放，因为当前 SDK
清除时基为 nil 会让内部渲染器停在零。门禁要求 `paused-layer-timebase-v1`
协议及每个像素的实际 `displayRate=0`；旧记录缺少这些字段不能升级为新协议证据。

macOS 验收还要求 `owned-all-spaces-window-v1` 与逐像素 `windowVisible=true`：
只有实际窗口位于当前桌面且未被系统标记为遮挡时才采样。验收窗口临时以400×260
的浮动小窗口显示在屏幕角落，可跨桌面显示，不激活应用或切换用户桌面。结束后恢复
本窗口原设置，过程中关闭窗口几何自动保存，不控制其他应用。旧记录缺少可见性字段
也不能作为当前门禁通过证据。

这些是 clear 内容的受控暂停快照，采集会调整显示时钟和验收窗口，不证明未经仪器干预的
连续显示、受保护读回、物理扬声器/屏幕同步、release 或完整格式矩阵。生产
解码准入、调度和显示实现不因采集而更改。

### iPhone 冻结构建采集

先用 `integration_test/bound_av_test.dart` 构建已签名的 Debug App，并在原生编译中
显式添加 `-D YL_BOUND_AV`。随后指定唯一物理设备和已构建 App：

```sh
python3 -B tool/media_matrix/run_bound_flutter_apple.py \
  --platform ios --device <UDID> --flutter <flutter-executable> \
  --app <Debug-iphoneos/Runner.app> --out <new-output-directory>
```

默认运行固定六控制；`--case <catalog-id> --transport file|http` 运行单格。
`run_bound_flutter_matrix.py` 接受相同的设备参数，固定保留 44 格（40 必需、2 诊断、
2 损坏输入），失败或不支持不会缩小分母。一次只让一个采集器使用该设备上的示例 App。

真机通过 Flutter `--no-hot --use-application-binary` 冷启动调试，禁用热重载代码同步。
CoreDevice 将最多 1 MiB 的一次性计划写入应用临时目录；只有显式验收 Debug 构建读取，
读取后立即删除，符号链接和无效内容被拒绝。安装产物及实际加载镜像仍由原生验证。
结果只从本次 UUID 的 appDataContainer 固定文件回收，每次复制使用新的本地目标，
并验证大小和 runId。采集超时、错误身份、框架失败、复制失败或未收到所属应用的
`app.stop` 成功回执都不能通过。输出保留原始记录、失败和清理结果供独立重放。

`renderPullAcceptance` 仅表示 AVPlayer source-pull 观测成立，不代表硬件已消费样本；
缺少该时钟的格仍会返回严格验收失败。设备实跑也不自动关闭 release、最低系统、Intel、
物理音画同步或软件解码长期热稳定性资格。

iOS 独立验收入口使用公开 `pluginManagedMediaPlayback` 管理音频会话；它没有额外的应用音频配置器。AVPlayer 空且无媒体区间的 tap 请求仅保留数字诊断，不推进观察范围；有帧/有效区间的错误仍拒绝。最新物理设备工程证据见[收尾清单](../../docs/superpowers/reports/evidence/2026-10-20-p03-engineering-completion/README.md)。
