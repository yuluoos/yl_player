# P03 格式组合与当前播放基线

2026-09-29，增量基线 `4833382`，开始时 `codex/fel-integration` 工作区干净。P07原始FEL/独立参考相关步骤保留未完成；按总览顺序推进独立的P03 Task1。本轮新增原创夹具、格式调查台账和macOS公共API基线，没有修改生产路由、FFmpeg模块、解码策略或软解预算。

## 样本与覆盖

[目录与验证入口](../../../tool/media_matrix/README.md)、[组合台账](../../../tool/media_matrix/cases.json)。17份夹具包含16份正常4秒媒体及1份32字节截断MP4，覆盖MP4/MOV/MKV/WebM/FLV/TS/PS/AVI、H.264/H.265/VP9/AV1，以及AAC/MP3/AC-3/E-AC-3/DTS/FLAC/Opus/Vorbis。另含HEVC Main10、AC-3 5.1和无Cues Matroska；MPEG-2/MP3是常规PS容器的辅助探测，不扩展REQ-10的视频支持承诺。17×3平台×2传输共102调查行，均保持unverified/not_run；错误扩展名是另外的同字节探测变体。

所有视频颜色和音调由本项目生成。FFmpeg8.0.1的精确命令、独立ffprobe输出、SHA256SUMS随资产保存；生产9.0.1不变。每行分列Profile、位深、声道、来源/哈希、4秒期望时长、probe时长与seek目标；`expected_seekable`不代表文件自带索引。

独立宿主解码验证16份正常片：第12/36/60/84帧颜色为red/lime/blue/white，RGB误差≤24/255；每秒各声道音调误差≤6Hz。该阈值只检查原创夹具是否生成正确，不是播放器画质/同步容差。首次5.1校验发现LFE被错误赋予高频，修正为60/70/80/90Hz，仅重新编码该片后验证通过；原失败日志与首轮播放记录保留。截断MP4被ffprobe拒绝；无Cues文件确实不含Matroska Cues ID。

## 公共路径实验与边界

`format_matrix_test.dart`对每份素材执行file、受控loopback HTTP及同字节`.bin`错误扩展名，共51项。使用automatic格式探测，依次检查ready、公共首帧事件、position推进、选中音轨、暂停/seek后推进、自然结束和释放。HTTP支持单个有起点的byte range，保留明确206/416行为；这不是弱网或完整HTTP服务器验收。

首轮按正常片全部可播的严格目标执行，完整收集51条：17条正常路径完成公开生命周期、31条正常路径失败、3条损坏输入拒绝；测试命令退出1，不能描述为51条支持通过。随后把每条实际outcome/stage/code/category/scope和里程碑固定为macOS27/Apple M1的**现状回归预期**，复验使用修正后的LFE媒体。

默认测试匹配 `baseline-macos.json` 的现状。failed/timeout继续原样写入 `YL_FORMAT_ROW`，不因预期匹配变成passed。`--dart-define=YL_FORMAT_REQUIRE_SUPPORT=true`保留严格支持门槛，正常素材缺口仍会失败。Android/iOS尚无现状基线，按严格目标运行；不能套macOS预期。仅公共事件/轨道/时钟被观察，播放器输出像素/物理声音/音频时标与同步未验收；相关字段保持false/null。所有CAP-FORMAT整体状态仍未完成。

已确认的失败阶段（具体组合/传输以最终观测为准）：

- WebM、TS、PS、AVI及本地FLV在自动路径加载时出现`container.unsupported`；不能据此断言对应系统或FFmpeg绝对无能力。
- MKV/AV1出现`decoder.unsupported`；MKV/FLAC出现`decoder.audio_unsupported`。
- MOV/HEVC及MKV/Main10均取得首帧，但seek后出现`decoder.video_decode_failed`；当前观察等待至15秒截止，保留timeout与实际decoder错误，不能写成单纯网络超时。
- HTTP/FLV取得首帧后seek出现`network.range_not_supported`；其本地路径与网络路径分别记录。
- 同字节MP4改为`.bin`后在ready阶段报`avplayer.-11828`，与正常扩展名结果不同，是后续实际内容探测需修复的缺口。
- 截断MP4正常名称报`avplayer.-11829`（source/session），错误名称报`avplayer.-11828`（container/session）。保留原码和实际分类，未伪造已统一为正式损坏错误。

## 验证、决定与下一步

台账测试先因缺实现失败，再8项通过：覆盖媒体被篡改、路径越界、漏平台、过早提升支持、非法时长、覆盖缺失与重复项。台账检查加入 `tool/check_foundation.sh`；原生公开入口通过Flutter integration_test实际发现51个样本/变体，未以mock代替播放。

本次决定：先保留真实现状基线，再按缺口扩展；代价是短小原创片与公开生命周期仍不能证明完整声音、像素或所有真实Profile。默认预期包含已知失败，只用于回归识别，严格支持模式和观测状态保留产品缺口。未触碰P08性能阈值或软件解码限额。

Task1的组合/素材盘点和macOS路由实验已交付，完整Task1仍缺其他平台及实际图像/声音/同步验证；Task2可依据明确的自动探测/容器/音频缺口开始。真实硬解生命周期、软件预算消费P08基线，不能从本次debug短播直接开放。最初错误工作目录的格式化/检索命令没有运行测试，不计入媒体失败；静态检查提示的两处花括号已修正。

## 最终实跑结果

macOS最终51项现状回归预期匹配，8项Python台账测试、35项example单元回归通过，Dart定向静态分析无问题。未运行无关完整播放器大套件。源与最终日志指纹见 [macos-observations.json](../../../tool/media_matrix/macos-observations.json)，夹具解码结果见 [fixture-verification.json](../../../tool/media_matrix/fixture-verification.json)。运行存在既有CocoaPods/SPM提示；不把debug运行视为最低系统或发布基线。

| 样本 | 本地 | HTTP | 同字节错误扩展名 |
|---|---|---|---|
| mp4-avc-aac | 公开生命周期通过 | 公开生命周期通过 | ready：格式识别错误 |
| mov-hevc-aac | seek：解码错误/等待截止 | seek：解码错误/等待截止 | seek：解码错误/等待截止 |
| mkv-avc-aac | 公开生命周期通过 | 公开生命周期通过 | 公开生命周期通过 |
| webm-vp9-opus | 加载：容器拒绝 | 加载：容器拒绝 | 加载：容器拒绝 |
| flv-avc-mp3 | 加载：容器拒绝 | seek：Range错误 | 加载：容器拒绝 |
| ts-avc-ac3 | 加载：容器拒绝 | 加载：容器拒绝 | 加载：容器拒绝 |
| ps-mpeg2-mp3 | 加载：容器拒绝 | 加载：容器拒绝 | 加载：容器拒绝 |
| avi-avc-mp3 | 加载：容器拒绝 | 加载：容器拒绝 | 加载：容器拒绝 |
| mkv-av1-opus | 加载：视频拒绝 | 加载：视频拒绝 | 加载：视频拒绝 |
| mkv-avc-eac3 | 公开生命周期通过 | 公开生命周期通过 | 公开生命周期通过 |
| mkv-avc-dts | 公开生命周期通过 | 公开生命周期通过 | 公开生命周期通过 |
| mkv-avc-flac | 加载：音频拒绝 | 加载：音频拒绝 | 加载：音频拒绝 |
| webm-vp9-vorbis | 加载：容器拒绝 | 加载：容器拒绝 | 加载：容器拒绝 |
| mkv-hevc-main10-aac | seek：解码错误/等待截止 | seek：解码错误/等待截止 | seek：解码错误/等待截止 |
| mkv-avc-ac3-51 | 公开生命周期通过 | 公开生命周期通过 | 公开生命周期通过 |
| mkv-avc-aac-no-cues | 公开生命周期通过 | 公开生命周期通过 | 公开生命周期通过 |
| mp4-truncated | ready：损坏拒绝 | ready：损坏拒绝 | ready：格式识别错误 |

上表不包含播放器像素/声音标记验收；“通过”仅限已列公共生命周期。后续优先修复自动格式探测/路由和HEVC seek，并逐行扩展已验证解码集合；不以删除失败行缩小REQ-10范围。

## 最终复审与文件身份

单次独立复审无Critical/Important/Minor发现；8项台账检查、所有样本/日志/执行代码哈希、51条原始观测及35项示例回归日志均核对。复审未评判的真实像素/声音/同步、其他平台/最低系统、硬解全生命周期、软解预算、弱网/长播与生产缺口修复继续保持未完成，没有从本轮短片测试提升支持声明；未再次派发复审。

- `tool/media_matrix/catalog.py`：`74ff868620200cfbb2ce9798ee3e927922367d702ca575634c4f6160e698c9b4`
- `tool/media_matrix/generate.py`：`0df57f187b3a6f34eff92027c2e27ca007903ce04e8c78bfff34a1f4a3a9df71`
- `tool/media_matrix/verify_samples.py`：`eccd158c51db09447043366dc411f62e0506c6662a850e9469eb32e76c23e11e`
- `tool/media_matrix/test_catalog.py`：`3eec1e4cf6001ddb32e0e44f804256a76225aa9785b861bf703b09544dc9947d`
- `tool/media_matrix/cases.json`：`6ce2c04000e80f0e6956246a49457548686ea8c71c0145823ed67a4bd81a5472`
- `tool/media_matrix/macos-observations.json`：`75546022786effe0657e4fc354689896f4ffe1828243fc6dd8f225af08474bac`
- `tool/media_matrix/fixture-verification.json`：`60b22acd837ca43eb2b21aa2f18718fdcae58685a8eff9a312a5436d3edd3d7c`
- `packages/yl_player/example/integration_test/format_matrix_test.dart`：`4949b3368784c85ff41de2167e984fe374edda7c671e1a8c64ff9c0b0ab51e10`

## Task2切片：MP4探测结果传递

2026-09-29，基线`d133977`。根因：`YlSourceInspector`在4KiB内识别ftyp并将formatHint设为mp4，但`YlAvPlayerBackend.installItem`只传URL，AVFoundation仍依据未知扩展名拒绝；原严格用例在ready报`avplayer.-11828`。新增无扩展名本地和`.bin` HTTP后，修复前10项严格测试中3条正常媒体变体失败、其余7项通过。

修复在创建资产时为已显式指定或已探测的MP4传`AVURLAssetOverrideMIMETypeKey: video/mp4`，URL、请求策略和生命周期不变；原生后续恢复也经过同一入口。使用本机Xcode公开SDK声明，API门槛macOS14/iOS17，带可用性保护，不提高macOS12/iOS15包部署下限。旧系统继续原路径，扩展名缺口仍未修复；没有通过私有key或静默软解绕过限制。自动路径仍只在原路由要求时探测，本轮不承诺把`.avi`等另一种已知扩展名也统一探测，MOV/HLS/DRM/FEL及裁剪FFmpeg不变。

本轮决定：先修复有现成失败证据的MP4格式传递，再逐切片推进容器扩展与HEVC seek。代价是旧系统、其他已知扩展名不符和其他格式仍需后续修复。本切片不代表Task1、Task2或CAP-FORMAT完成。

验证命令在`packages/yl_player/example`执行：

```sh
flutter test integration_test/format_matrix_test.dart -d macos --no-pub --dart-define=YL_FORMAT_REQUIRE_SUPPORT=true --name '^(mp4-avc-aac|mp4-truncated) /'
flutter test integration_test/format_matrix_test.dart -d macos --no-pub
```

首条严格专项修复后10项通过：5条正常MP4路径都完成首帧、position、选中音轨、seek、自然结束和释放；5条截断路径均在ready报`avplayer.-11829`，category=source/scope=session，没有首帧且释放完成。截断`.bin`不再误报不识别格式，但仍保留系统错误码；不是新增通用损坏媒体错误映射。所有素材字节及hash不变；默认基线仅更新实测受影响的MP4行。运行提示前台激活失败及既有构建提示，不影响实际公共路径测试；不计为视觉/声音输出验证。

最终55项格式基线预期全部匹配（命令退出0）：20条正常路径完成公共生命周期，30条有效素材缺口仍失败/超时，5条截断输入拒绝；所有55条释放完成。相对原51项，仅原有MP4 `.bin`正常路径从失败转通过、截断`.bin`错误分类修正；新增4项贡献2条正常通过及2条截断拒绝，不能把新增样本数当作修复数。8项Python台账、35项example回归通过，定向Dart分析无问题；源迁移身份检查通过。本次没有运行无关完整原生矩阵。

当前逐条观测及执行源/日志hash见[macos-mp4-mime-observations.json](../../../tool/media_matrix/macos-mp4-mime-observations.json)。原始51项证据`macos-observations.json`及本文前述表格/指纹保留历史身份，当前55项以新文件为准。

单次独立复审无Critical/Important/Minor。复审未独立验收的旧系统、iOS/Intel、已知错误扩展名、像素/声音/同步/Profile/多声道、强制硬解重建/软件预算/HDR策略，以及HEVC/其他容器/无索引完整验收继续保留缺口；显式提示及恢复入口仅代码流检查，本轮无独立运行测试。复审时尚未结束的55项回归现由主执行者确认通过，未再派发复审。这些边界均不提升整体能力状态，代价是相关平台/场景仍需独立证据。

本切片最终源文件身份：
- `packages/yl_player/example/integration_test/format_matrix_test.dart`：`10ae93015e16782d29c1baae6fb913861677bd5b52b18e330d91f7c7709e58c5`
- `packages/yl_player/example/assets/test_media/format_matrix/baseline-macos.json`：`5815e05156ba0f13d1b50323514607ad0355f83ce1d10124f678aefdae8cf48c`
- `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines/AvPlayer/YlAvPlayerBackend.swift`：`b9b516e70fa809274009a7fd09675d7a7e7573a1dd3efda4b0b94732e3fbe7bc`
- `tool/media_matrix/macos-mp4-mime-observations.json`：`a95c029158b63b2d1c660934ecf47daf68a23e3a8d8d9cb5b4355f48738aea64`
