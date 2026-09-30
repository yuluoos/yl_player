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

## HEVC跳转切片：随机访问前置帧

2026-09-29，基线`9cd27e7`，开始工作区干净。严格运行MOV HEVC和MKV Main10的file/http/renamed-file共6条路径，全部在seek后出现`decoder.video_decode_failed`（等待最终截止）；不是网络或容器打开失败。独立ffprobe在两份既有样本的2秒落点均读到CRA(type21)，后续3个解码顺序上的访问单元分别为RASL_R(type9)、RASL_N(type8)、RASL_N(type8)，显示时间均早于CRA。现有seek事务重新创建VideoToolbox解码器，旧参考图像不在新实例中，但此前仍向它提交RASL。[RFC7798随机访问说明](https://www.rfc-editor.org/rfc/rfc7798.html#section-1.1.2)明确区分可解的RADL与随机访问时不可解的RASL。

修复只在普通`YlVideoPipeline`提交路径增加HEVC随机访问过滤：每次安装资源重置；从CRA开始或遇BLA时丢弃关联RASL，连续播放经过后续CRA则保留RASL；保留RADL和普通帧。NAL长度前缀支持1/2/4字节，完整验证边界/头部/同一图像类型后才更新状态；无效/多层/未知结构交回原解码路径，不把错误伪装成成功。读取bridge已持有的连续CMBlockBuffer头部，不拷贝媒体负载、不增加未计量帧缓存；丢弃时释放提交预留，sample正常释放原packet。FEL走原独立分支，解码策略、硬件证据、固定档位/HDR约束、FFmpeg制品和部署下限不变。

本次决定：采用解码序列边界上的RASL语义过滤，不扩大软解或忽略VideoToolbox错误；代价是其他未支持的输入表示仍沿用已有失败路径。没有声称所有HEVC Profile/FEL/实际输出均通过。

验证入口：

```sh
sh tool/media_matrix/check_hevc_random_access.sh
# 在 packages/yl_player/example 下
flutter test integration_test/format_matrix_test.dart -d macos --no-pub --dart-define=YL_FORMAT_REQUIRE_SUPPORT=true --name '^(mov-hevc-aac|mkv-hevc-main10-aac) /'
flutter test integration_test/format_matrix_test.dart -d macos --no-pub
```

新增纯Swift状态/边界入口有56项断言，并接入`check_foundation.sh`的macOS发现路径。实际播放先6项失败，再6项通过；随后将HEVC公开用例加严为先seek2秒、再反向seek1.25秒并继续到自然结束，6项再次通过。初次Swift独立编译被默认模块缓存权限阻止，不计行为失败；改用临时模块缓存后成功。Dart格式化写入成功后的遥测文件权限提示也不计播放失败。

最终55项格式基线全部匹配（退出0）：26条正常路径完成公开生命周期、24条有效素材缺口仍失败、5条截断输入拒绝，所有行释放完成。与上一轮同55项相比，6条HEVC缺口转为通过，其余行结果不变；不是55条格式支持。35项example回归、8项Python台账通过；56项Swift断言由主执行者和独立复审者分别运行通过；Dart定向分析/格式检查及源迁移身份/36项资产指纹检查通过。未重复无关完整原生矩阵。

单次独立复审无Critical/Important/Minor。复审暂未判断的真实像素/声音/同步/Main10输出质量、iOS/Intel/最低系统、FEL物理输出、hardwareRequired全生命周期故障注入/持续资源性能，以及其他格式/损坏/无索引完整验收继续保持未完成。复审期间待结束的55项回归已由主执行者检查最终结果与全部媒体/预期身份；未再次派发复审。明确代价是这些平台和完整输出要求仍需各自证据，不据此封板P03。

当前55项原始行、独立NAL类型探测、工具版本与源/日志指纹见[macos-hevc-seek-observations.json](../../../tool/media_matrix/macos-hevc-seek-observations.json)，前两轮文件保留历史身份。本切片最终源身份：
- `packages/yl_player/example/integration_test/format_matrix_test.dart`：`f94ef19bd16db2517a1e4732c04009a4baf948cf2182fef92b7515cbf2ff54bf`
- `packages/yl_player/example/assets/test_media/format_matrix/baseline-macos.json`：`9c802654b6b9b328442443d71677d4ce0df9de9d1ab7a4210db931b3216bfa27`
- `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/VideoToolbox/YlVideoPipeline.swift`：`6cd01b4bdb5199070ebd6ec98ae9df3ae5af5882472690675a9fa830c3a10ca4`
- `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/VideoToolbox/YlHEVCRandomAccessGate.swift`：`c8042be62235cd84adeb7191583b0eae197f2ca36b4a790aafc7f82c4675ccf8`
- `tool/media_matrix/hevc_random_access_test.swift`：`50e37cf2a2b919834cdd41de5dae2a439754fa8e4adb039b472fc335bec7a201`
- `tool/media_matrix/check_hevc_random_access.sh`：`2342dd7aca399ecefe9a5eee56ba82a6a4df5f169ecf3667cec4ac83aa8bb0b5`
- `tool/media_matrix/macos-hevc-seek-observations.json`：`1951b1324042da180dadb8c5b28393f80ba14a31e51046f87462279e228ec5df`

## FLV点播切片：分离播放意图与传输能力

2026-09-29，基线`19e0244`，开始工作区干净。严格复现3条既有AVC/MP3 FLV路径：本地与同字节`.bin`在加载时被路由拒绝；HTTP声明onDemand但仍被当作直播，seek报`network.range_not_supported`。生产bridge已包含FLV解复用且接受本地输入，本轮无需扩大FFmpeg模块。

修复启用本地FLV的待探测路由；仍由fallback准备验证真实媒体、codec及策略后提交。文件作为点播；网络显式onDemand使用现有randomAccessVOD传输，其余automatic/live保留顺序直播兼容行为。`YlFallbackMediaPolicy`分别记录是否直播和实际字节源随机访问能力：点播可报告媒体时长，但仅真实支持Range时才可seek。RTMP请求仍先走原有地址/意图校验，本轮未改变RTMP连接或重连实现；HLS、FEL、decoder、buffer预算、凭据过滤、取消/重试机制和部署下限不变。

本次决定：automatic HTTP-FLV继续直播语义，HTTP点播调用方应显式传onDemand；代价是不会靠有限响应自动猜测点播。局部路由开放不代表FLV任意codec/损坏索引均受支持。

3条严格公开路径修复后通过首帧、音轨选中、时钟推进、前向2秒/反向1.25秒seek、自然结束和释放，且断言isLive=false、isSeekable=true、duration非空。新增`flv_intent_test.dart`对无Range的HTTP200服务执行automatic/onDemand/live：3项均通过；onDemand发Range请求但不虚报seekability、保留时长，automatic/live不发Range且不报告点播时长；seek均以`network.range_not_supported`和command范围拒绝，当前会话无终止错误。原有HTTP-FLV断线重连测试通过，验证首帧、重连、live/nonseekable及自定义header保留。新意图测试已加入`check_native_macos.sh`发现清单。

命令（Flutter从`packages/yl_player/example`运行）：

```sh
flutter test integration_test/format_matrix_test.dart -d macos --no-pub --dart-define=YL_FORMAT_REQUIRE_SUPPORT=true --plain-name 'flv-avc-mp3 /'
flutter test integration_test/flv_intent_test.dart -d macos --no-pub
flutter test integration_test/macos_http_flv_playback_test.dart -d macos --no-pub
flutter test integration_test/format_matrix_test.dart -d macos --no-pub
```

脚本契约7项检查首次有1项因沙箱禁止`ps`读取测试自建子进程而报错；授权执行重跑后7项通过，不计为播放器失败。原始失败日志保留。原生运行仍有既有构建/前台激活提示；没有用这些测试代替像素、物理声音或同步验收。

最终55项格式基线全部匹配（退出0）：29条正常路径完成公共生命周期、21条有效素材缺口仍失败、5条截断输入拒绝，全部释放完成。相对上一轮同55项，仅3条FLV缺口转为通过；已有MP4/HEVC修复结果不变，不将已知失败的预期匹配当作支持。35项example回归、8项Python台账、7项原生脚本契约检查通过，2个Dart入口定向分析无问题，36项资产/台账指纹核对通过。未运行完整原生聚合门禁；专项入口分别执行。

单次独立复审无Critical/Important/Minor新增问题。复审未判断的独立声音/像素/同步、异常FLV/无索引及更广泛错误扩展名、其他codec/Profile/位深/声道、iOS/Android/其他设备/最低系统、真实RTMP/长时网络恢复、资源曲线/硬解失效注入/严格策略全组合继续保持未完成；代价是这些范围仍需单独证据。复审时待完成的前后seek、直播回归、55项基线和文档已由主执行者补齐并核对，没有再次派发复审。P03整体不封板。

本轮原始55条观测、日志及执行源hash见[macos-flv-vod-observations.json](../../../tool/media_matrix/macos-flv-vod-observations.json)，前轮文件均保留历史身份。最终源文件指纹：
- `packages/yl_player/example/integration_test/format_matrix_test.dart`：`70f5e40e47336f851384e5f86f1e0c503709b9692aedf47571f66e262fca7107`
- `packages/yl_player/example/integration_test/flv_intent_test.dart`：`ec2de7642f1dff817d7a1f671d55ba9e76d45000e32ac749c5f9376eb8df7f9b`
- `packages/yl_player/example/assets/test_media/format_matrix/baseline-macos.json`：`6fb3d1a591b1488a36bf045fabbb09c0bd7e39cb930f6c080a33ec9653378dda`
- `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/FFmpeg/YlPreparedFallback.swift`：`7f34aec2ae585c686f045ab8ed22ad31d533fea819776527a10118f1d901be57`
- `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/Session/YlFallbackRecoveryPolicy.swift`：`fe93611aa5c5a5645cf56a837a8c92d5ef74dd0b0043658d70f92cc898b6138d`
- `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/SourceRouting/YlSourceAssessment.swift`：`19f1078927f023c18617478b2f57f8892c8779aaa8d63e4eea0a1ca8eb24a390`
- `tool/check_native_macos.sh`：`1119e0b3df744f864253cc5530f921ee32d77a98106ada77f889639d797a8ca7`
- `tool/media_matrix/macos-flv-vod-observations.json`：`4da69e048de61d0f5d94b6c6e8de6976965a5c338e43520f5b1fca8d9910e5e4`

## FLAC音频切片：系统解码与有界PCM

2026-09-29，基线`e2c9e98`。先复现MKV AVC/FLAC的本地、HTTP和改名文件3条严格测试，均在load报`decoder.audio_unsupported`。WebM还缺VP9、Opus/Vorbis桥接及解码，不能仅打开路由；本轮先交付独立FLAC音频链路，WebM仍未完成。

bridge新增稳定codec ID8，保留0–7原值。准备阶段精确读取34字节STREAMINFO，校验长度后才分配；系统转换器校验采样率、16/24位及单/双声道，构造CoreAudio dfLa cookie。输入ASBD使用最大block长度，各packet按帧头报告实际样本数，末帧不会补成整帧；PCM分配受STREAMINFO上限和实际帧头双重约束，不采信任意packet duration放大分配，沿用既有Player缓冲账本。配置不支持时发布明确且不含输入数据的`decoder.audio_flac_unsupported`。FLAC帧格式依据[RFC9639](https://www.rfc-editor.org/rfc/rfc9639.html)，CoreAudio参数由本机SDK与独立探针核对。

不增加商业SDK或FFmpeg decoder/parser/demuxer。固定签名FFmpeg9.0.1的五目标候选产物经第二次独立重建，18个规范文件/符号链接逐字节一致，再显式更新制品、lock及接受的provenance哈希；macOS12/iOS15下限不变。制品契约验证3slice/5架构/30符号和3项负例，音频metadata30项、视频metadata35项通过。五架构产物构建不能代替iOS/Intel运行时验收。

新增原生测试用原创整数斜坡，覆盖16位mono和24位stereo、48kHz，每段1000样本（576+424）。使用生产转换器逐样本比较独立计算的Float PCM，检查声道顺序、容量/时长、时间戳/generation、短末帧及reset后重复转换；拒绝缺失/错长cookie、采样率/声道不一致、未支持位深、截断及超大block帧头，使用Int64.max包时长验证分配不随之膨胀。原生音频类17项通过，无跳过；包含原有AAC/MP3/Dolby及音频生命周期回归。公开格式测试只证明生命周期，独立PCM证据仅适用于上述两份夹具，不能推广为物理声音、完整A/V同步或所有FLAC Profile通过。

验证中保留失败记录：第一次Xcode运行因Flutter临时入口已被清理而构建失败；修复入口后定位CoreAudio不接受FLAC的零framesPerPacket；PCM通过后修正一条误改totalSamples而非位深的负例；公开播放进一步发现准备阶段仅复制AAC cookie并补齐FLAC传递。沙箱音频探针/缓存访问和离线制品验签环境问题不计为播放器支持结果。

三条严格公开生命周期全部通过：file/http/同字节.bin均通过首帧、音轨选中、时钟推进、前向2秒/反向1.25秒seek、自然结束及释放。最终55项基线全部匹配（退出0）：32条正常生命周期完成、18条有效素材缺口、5条截断输入拒绝；全部释放完成，媒体hash逐项核对，仅3条FLAC缺口转为通过，其余52条原始观测与上一轮相同。已知失败仍记录failed，不视为格式支持。范围仍限macOS当前设备证据；其他位深/多声道、其他容器、物理输出/同步、iOS/Android/最低系统、硬解失效和持续资源预算均未完成，P03整体不封板。


单次独立复审无Critical/Important/Minor。决定保持上述受检范围：其他位深/多声道/未测采样率与容器、物理输出/完整同步、其他设备/iOS/Intel/最低系统、更广错误扩展名/损坏/无索引、hardwareRequired重建/视频软解预算/HDR或分辨率策略、持续资源及候选/当前共存均不由本切片验收；代价是这些范围仍需独立证据。复审未重跑的strict3/full55最终结果已由主执行者检查，不再次派发复审。源与日志指纹、55条原始观测、独立PCM测试结果见[macos-flac-observations.json](../../../tool/media_matrix/macos-flac-observations.json)，历史证据均保留。

命令（Flutter在`packages/yl_player/example`运行）：

```sh
flutter test integration_test/format_matrix_test.dart -d macos --no-pub --dart-define=YL_FORMAT_REQUIRE_SUPPORT=true --plain-name 'mkv-avc-flac /'
flutter test integration_test/format_matrix_test.dart -d macos --no-pub
# Xcode原生定向入口（先 flutter build macos --debug --config-only）
xcodebuild test CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:RunnerTests/YlMacosAudioTests
```

补充回归：35项example单元测试、8项Python台账检查通过，Dart定向分析无问题，36项素材/台账指纹及原生测试源对齐检查通过。未执行完整原生聚合门禁；已执行本轮17项音频原生类、3项严格FLAC和55项格式回归。

## 独立MPEG-TS点播切片

2026-09-29，基线`bfcadf6`，初始工作区干净。既有`ts-avc-ac3.ts`的file/http/同字节.bin三条严格路径先失败，均不能建立支持路由；新增原生签名/策略测试也实际失败。本轮消费现有FFmpeg MPEG-TS解复用、Annex-B视频及AC-3路径，增加独立TS路由/容器身份，不把TS当Matroska或HLS播放列表。

有限前缀检查3个连续TS包头，可识别188字节TS、带4字节前缀的192字节M2TS及204字节TS；只有188字节AVC/AC-3样本进入本轮实际播放验收，其他两种包尺寸目前只有探测单元证据。后续仍需解复用和真实codec准备，签名不等于支持。automatic/onDemand是点播；live意图以`container.mpegts_live_unsupported`拒绝。`network.managed`、`buffer.bounded`和`hardwareRequired`本轮继续明确拒绝，不推断完整严格策略已验收；代价是这些TS选项仍待独立工作。

独立probe确认素材容器start_time=1.4s、duration=4.005333s。直接暴露原始PTS会把片内2秒seek当成绝对2秒，原生时间轴测试初跑17检查有4项失败。新增显式bridge接口，在独立TS打开后且未持有packet时启用相对时间：保留统一format origin，音/视频packet PTS/DTS与CMSampleBuffer均减去相同origin，seek目标加回origin；保留负DTS和未知时间，防止加减溢出。HLS有独立time-seek回调，拒绝该接口；其他上下文默认origin=0。26项时间轴检查通过，包含初始相对时间、AV偏移、sample时间、前后seek、溢出/缺失值及HLS所有权边界。普通视频metadata35项通过；FEL入口仅运行无输入的2条基础断言，不冒充真实FEL素材或输出回归。

codec ID、FFmpeg版本/模块/许可证、网络禁用边界、iOS15/macOS12部署下限不变。为导出新增时间轴接口重建五目标产物；候选独立重建及原生/公开最终验收结果在本节后续记录。WebM/VP9/Opus/Vorbis及PS/AVI仍未完成，P03不封板。

公开seek首次触发`decoder.video_decode_failed`：重建decoder后未重置既有等待关键帧门控，补齐reset后三条生命周期通过。但独立packet核查发现1.25s反向seek从后方2.005s关键帧开始；强化“关键帧必须位于目标之前”的测试再次RED。最终新增1/2/4/8秒逐级回看，每次最多512个解复用packet/8MiB扫描；找到目标前关键帧后重新定位并经既有门控/preroll与目标前呈现抑制恢复。不能找到时明确失败，不能静默跳过目标。30项原生TS检查通过，包含新生成的12秒稀疏GOP媒体：10秒seek因8秒范围内无关键帧而拒绝，随后seek零仍成功。这里的搜索上限是工程保护，不等于软解预算或持续资源验收。

损坏TS公开测试发现Dart固定消息表覆盖了原生详细提示，导致`Playback operation failed.`；新增open/seek/malformed/live四类安全固定消息。对应单测实际RED后18项通过，Apple错误适配与编解码37项通过。输入路径/凭据和原生错误文本不拼接到这些消息中。

最终关键帧桥接候选重新完成五目标构建，第二次独立重建18个规范文件/符号链接逐字节相同后采纳；制品契约3slice/5架构/31个Swift消费符号和3项负例通过。音频metadata30项、视频metadata35项及TS30项通过。构建签名与FFmpeg模块保持原约束。采纳时第一次指纹更新脚本因引号格式未匹配而未写入新hash，契约正确拒绝旧hash；修正接受的指纹后通过，未修改验签标准。

最终产物3条严格TS公开路径通过：相对时间从零附近开始、约4秒时长、首帧、音轨选中、前向2秒/反向1.25秒seek、自然结束及释放。首次原生定向29项中28通过、1失败：生产本地FLV的旧严格策略测试仍期待`policy.unsupported`，与前一FLV切片已开放的行为不符；仅更新生产矩阵预期，注入的未开放availability预期保留。Dart format曾因缓存/遥测写入沙箱受限退出，格式修改本身完成；后续授权检查单独核对。

最终TS策略3项全部通过：live/managed/bounded/hardwareRequired在网络访问前拒绝；损坏候选以明确TS错误返回且保持现有会话可暂停、seek及继续播放；无Range的HTTP200服务可播放但不虚报seekability，seek以command错误拒绝。最终原生32项通过、0失败/0跳过，覆盖路由矩阵/TS探测/候选保留、17项音频、3项FEL管线、3项HLS探测/取消/直播路由。FEL管线单元测试不是实际FEL显示验收；HLS探测回归不是完整HEVC-HLS seek验收。

单次独立静态复审无Critical/Important/Minor；由主执行者补齐最终制品和运行时结果。复审后仅修正已复现的旧FLV/HLS测试预期、格式化和证据文档；未改变生产范围。未执行完整原生聚合门禁，定向结果不能替代跨端完整验收。

最终55项格式基线全部匹配（退出0）：35条正常播放生命周期完成、15条有效素材支持缺口、5条损坏输入拒绝，全部释放完成。与上一轮55项逐行对照，只有3条TS由失败转为通过，其余52条原始观测相同；仅更新已实测的3条baseline预期及其SHA256SUMS条目，36项素材/台账指纹核对通过。记录见[macos-mpegts-vod-observations.json](../../../tool/media_matrix/macos-mpegts-vod-observations.json)，含原始55行、执行代码与日志指纹；历史证据保留。已知失败的预期匹配不计为支持，P03整体不封板。

主要复现命令（Flutter从`packages/yl_player/example`运行）：

```sh
flutter test integration_test/format_matrix_test.dart -d macos --no-pub --dart-define=YL_FORMAT_REQUIRE_SUPPORT=true --plain-name 'ts-avc-ac3 /'
flutter test integration_test/mpegts_policy_test.dart -d macos --no-pub
flutter test integration_test/format_matrix_test.dart -d macos --no-pub
# 仓库根目录，使用固定签名9.0.1保留构建的库：
YL_TEST_FFMPEG_BUILD=<retained-build-root> sh packages/yl_player_apple/tool/apple_ffmpeg/test_video_metadata.sh
```

搜索测试额外使用本机FFmpeg8.0.1生成原创12秒黑色视频稀疏GOP，仅作为负例夹具；实际产品与原生测试链接的FFmpeg仍为固定9.0.1。未验收192/204实际播放、完整HEVC-HLS seek、独立TS其他codec/异常时间轴/多节目/长时seek及断续恢复、物理输出/完整同步、iOS/Intel/最低系统和资源预算。搜索失败有明确错误，但本轮不把这些有限样本推广为所有TS支持。

附加公开HLS回归首次在末尾UI断言失败：首帧/时钟/暂停已通过，但旧测试仍查找Flutter Texture；现有`YlPlayerView`在Apple普通视频路径已使用先前提交的原生AppKitView。本次改为断言原生视图存在且viewType与公开surface一致，未调整播放器显示实现。

最终公开HLS回归1项、example单元35项均通过，3个Dart入口分析无问题，Python台账8项通过，Apple测试源对齐iOS657/macOS574。原始HLS失败与修复后日志均纳入证据指纹；未将平台视图存在等同于像素或HDR显示验收。


## AVI点播切片

基线`2e4b7ea`，初始工作区干净。既有原创`avi-avc-mp3.avi`为320×180/24fps Constrained Baseline AVC与48kHz双声道MP3，SHA256 `8507c46ff72fe8b923ae2eb510ce3de431caaa708965fe028c0cbf0deaabeccc`。file/http/同字节.bin三条严格公开测试实际RED，均在load报`container.unsupported`；原生有索引和移除idx1两份输入也无法打开。选择AVI先于WebM/PS是因为样本可复用已有视频和音频解码链；WebM仍缺完整VP9/Opus/Vorbis，现有PS样本需要MPEG-2视频路径，均保留缺口。

只为固定签名FFmpeg9.0.1增加AVI demuxer，不新增decoder/parser、商业SDK或网络模块，不提高iOS15/macOS12下限。AVI具有独立路由和容器身份，文件与普通HTTP automatic/onDemand走点播；live、managed/bounded/hardwareRequired继续明确拒绝。字节前缀沿用已有RIFF/AVI探测，真正支持仍依赖准备阶段解复用与codec校验；HTTP seekability由实际Range能力决定。

第一版仅打开解复用后，原生53项检查26失败：裁剪产物未从packet补齐SPS/PPS，AVI视频PTS缺失，无idx1的合成索引也可能落到P帧。将既有Annex-B探测扩展到AVI，AVI探测最多512packet/8MiB；缺失PTS仅在AVC Baseline/Constrained Baseline且声明video_delay=0、DTS存在时补为DTS，已有PTS保持不变。未知Profile、Main/High或重排/缺DTS不猜测，发布`container.avi_timing_unsupported`。没有开启可能向前累计媒体的通用GENPTS路径。

AVI seek复用TS的1/2/4/8秒有限关键帧定位，每次最多512packet/8MiB；回放探测起点后，由既有关键帧门控和目标前呈现抑制完成preroll。无idx1用复制样本删除完整索引chunk并更新RIFF大小构造，不修改原始夹具。原生测试原先要求首个demux packet就是关键帧且限1.1秒回看，与真实门控和8秒上限不符；改为检查门控后首个关键帧在目标之前且位于允许窗口。88项AVI检查通过，包括有/无idx1前向2秒、反向1.25秒及零、sample时间和不允许推断PTS的边界；既有视频metadata35项、TS30项通过。

中间保留环境失败：首个候选构建结束清理临时目录，使使用已清理headers的探针编译失败；改为直接链接候选framework验证，第一次传相对路径被本地输入接口拒绝，换绝对路径后获得上述实际26项失败。另建独立macOS测试库用于快速验证，最终产品仍须五目标独立复建通过后采纳；这些探针/环境失败不计为播放器支持结果。

最终五目标候选对应的保留构建库再次通过AVI88、TS30、video35、audio30检查。二进制大小变化（字节）：iOS device 2182904→2219128，iOS simulator合并4349360→4402160，macOS合并4362240→4415008。错误提示19项、Apple适配/codec37项、example35项、Python台账8项通过；2个Dart入口分析无问题。单次独立静态复审无Critical/Important/Minor，运行时和制品复建仍由主执行者继续核对。

最终候选完成第二次独立五目标重建，18个规范文件/符号链接逐字节一致后才替换制品、lock及接受的来源哈希。契约验证3slice/5架构/31个Swift消费符号、3项负例通过；导出API/codec ID均未扩展。构建切片不能替代iOS/Intel/最低系统运行时证据。

最终产物3条严格公开路径全部通过：首帧、音轨选中、时钟推进、点播/可seek/时长元数据、前向2秒和反向1.25秒seek、自然结束与释放；本机报告managedFallback/hardware。策略4项通过：明确live及managed/bounded/hardwareRequired在网络访问前拒绝；损坏候选返回不含路径的AVI错误且现有会话仍可继续；本地移除idx1后完成前后seek和自然结束；无Range HTTP200服务可播放但不宣称可seek，seek返回command范围`network.range_not_supported`。仅更新3条已实测的AVI基线预期及对应SHA256SUMS；36项素材/台账指纹核对通过。

最终原生定向33项通过，0失败/0跳过，含路由/AVI/TS、17项音频、3项FEL管线和3项HLS探测。并未执行完整原生聚合门禁，FEL单元和HLS探测不代替实际FEL画面或完整HEVC-HLS跳转。移除idx1的派生样本为79288字节，SHA256 `b74ef7699cd990c3a75d427ea70c88dcd0b60dbab6bf04ec1845294d7af686e0`；只更改索引chunk和RIFF长度，媒体payload保留。

最终55项基线全部匹配（退出0）：38条正常播放生命周期完成、12条有效素材支持缺口、5条损坏输入拒绝，全部释放完成。与上一轮55条逐项比较，仅3条AVI由失败转为通过，其余52条原始观测相同；预期失败不计为格式支持。原始行、日志与执行源指纹见[macos-avi-vod-observations.json](../../../tool/media_matrix/macos-avi-vod-observations.json)，保留历史TS/FLAC等证据。Apple测试源对齐iOS658/macOS575；最终静态复审未要求代码修改。

复现命令（Flutter从`packages/yl_player/example`运行）：

```sh
flutter test integration_test/format_matrix_test.dart -d macos --no-pub --dart-define=YL_FORMAT_REQUIRE_SUPPORT=true --plain-name 'avi-avc-mp3 /'
flutter test integration_test/avi_policy_test.dart -d macos --no-pub
flutter test integration_test/format_matrix_test.dart -d macos --no-pub
# 仓库根目录，固定签名FFmpeg9.0.1的保留构建：
YL_TEST_FFMPEG_BUILD=<retained-build-root> sh packages/yl_player_apple/tool/apple_ffmpeg/test_video_metadata.sh
```

本轮不验收AVI其他codec/Profile、重排帧的缺失PTS重建、OpenDML/多段/大文件、任意损坏或异常索引、物理声音/像素/同步、跨端/最低系统、资源曲线和严格策略。上述搜索/探测限制是工程防护，不代表完整FFmpeg索引操作或软解性能预算。未新增软件视频解码，P03 Task1/Task2与CAP-FORMAT均继续保持未完成。

## 2026-09-29 Opus 原生制品前置切片（尚未开放播放器）

起点 `ea8de71`。本轮先实现低层 `ylf_opus_create/decode/reset/free`，不修改 Swift codec 映射、容器路由或公开能力行。当前 macOS 27 的公开 `AVAudioConverter` Opus 创建探针返回 nil，因此选用同一签名 FFmpeg 9.0.1 的原生 Opus decoder，增加它要求的内部 `libswresample`，不使用私有系统注册接口、商业 SDK 或产品外部 libopus。部署下限保持 iOS 15/macOS 12。

桥接当前只接受 OpusHead v1、mapping family 0、mono/stereo，输出 48 kHz interleaved float PCM；仅开放 CELT 包。按 [RFC 6716 TOC](https://www.rfc-editor.org/rfc/rfc6716.html#section-3.1) 限制每包最多 120 ms / 5760 frames，输入上限 64 KiB，分配前检查；不依据容器 duration 分配。按 [Opus 头及裁剪语义](https://www.rfc-editor.org/rfc/rfc7845.html#section-4) 由调用者显式传入 skip/discard，桥接不再次自动应用头部 pre-skip，返回首部裁剪的 frame offset。skip 可跨包，reset 清除 skip 与历史。无效参数和不支持模式在消费前拒绝；真实解码失败后要求 reset。

原创 4 秒音调夹具覆盖 mono/stereo 的 2.5/5/10/20/40/60/120 ms 包及 +6 dB OpusHead gain，独立参考由主机 FFmpeg 8.0.1 的 libopus decoder 生成，产品使用 FFmpeg 原生 decoder。已测 CELT 每条均精确输出 192000 frames，未对齐 PCM SNR 约 70–76 dB（门槛 50 dB），检查头尾裁剪、完整包跳过、容量/畸形输入及 reset 后一致性。2.5 ms 夹具最后恰好落在包边界，合法无尾部 padding。

SILK 的 8→48 kHz 重采样输出与 libopus 有约 2 samples 偏移；即使对齐，原始实验 mono/stereo SNR 也只有 38.50/39.96 dB。本轮不继续降低标准，明确返回 `YLFResultAudioConfigurationUnsupported` 拒绝全部 SILK/hybrid TOC。该差异并未证明整个 Opus 格式不成立，后续仍需独立解决。现有 WebM VP9/Opus、MKV AV1/Opus 公开缺口不变，完整 Opus 支持保持未完成。

复审发现非法 skip/discard 重叠会提前推进 decoder；已新增“拒绝后重试与全新 decoder PCM 一致”的回归并观察失败，再将校验移到 decode 前。源代码回归已通过；最终制品复建、制品直连和消费者回归结果记录于下方最终证据。

复现命令（仓库根目录）：

```sh
YL_TEST_FFMPEG_BUILD=<retained-signed-build> sh packages/yl_player_apple/tool/apple_ffmpeg/test_audio_codecs.sh
YL_TEST_FFMPEG_BUILD=<retained-signed-build> sh packages/yl_player_apple/tool/apple_ffmpeg/test_video_metadata.sh
sh packages/yl_player_apple/tool/apple_ffmpeg/test_build_contract.sh
```

`test_audio_codecs.sh` 自动发现并执行 `test_opus.sh`；Opus 同时验证源文件直连和真实 XCFramework。候选验收可通过 `YL_OPUS_FRAMEWORK_DIR` 指向候选 macOS slice。主机 FFmpeg 对每份 Matroska 参考输入会输出一次 Opus header 探测错误；参考解码命令退出 0，实际 PCM frame 数和逐样本对照另行检查，不能把日志静默或退出码单独当作正确性证明。

下一切片仍需把容器 CodecDelay/pre-skip、DiscardPadding、seek preroll 传给音频转换器；当前 demux 在解码前丢弃 seek 前音频，不能直接启用 Opus 映射。其后再验收 AVC/Opus 独立组合、WebM 视频路径、物理输出/同步、严格缓冲预算、其他平台和最低系统。

最终原生制品：新候选经独立五目标重建，18 个规范文件/符号链接逐字节一致，再更新制品、lock 和接受哈希。契约 3 slices / 5 architectures / 31 Swift symbols 与 4 个 Opus 导出、3 项预期负例通过。制品大小：iOS device 2,219,128→2,423,440 bytes；simulator universal 4,402,160→4,837,920；macOS universal 4,415,008→4,850,304。增加来自 Opus 及其内部 swresample，未增加外部运行库。

最终源码/制品各 9 组模式测试退出 0：16 份 CELT 夹具各做两次 PCM 对照（32 条观测），另 2 份语音夹具各做两次明确拒绝；参数/状态/边界检查总计 55,884 次断言，0 失败。既有 audio metadata 30、video metadata 35、TS 30、AVI 88 检查通过，FEL C 基础烟测退出 0；macOS 原生音频 17 + FEL 管线 3 项全部通过、0 失败/跳过。尚未执行完整原生聚合门禁。

最终55项公开基线全部匹配，38条正常生命周期、12条有效素材缺口、5条损坏输入拒绝；55条原始观测与AVI切片逐项完全相同，不新增格式支持声明。8项Python台账检查通过，Apple测试源对齐iOS658/macOS575；初次从仓库根目录调用unittest因本地模块搜索路径错误失败，改在tool/media_matrix执行后通过。最终不可变制品验签/哈希验证再次通过。完整样本及参考PCM哈希、32条PCM观测、SILK失败实验、制品/源指纹和55条公开观测见[macos-opus-bridge-observations.json](../../../tool/media_matrix/macos-opus-bridge-observations.json)。

独立复审共1项Important，已通过重叠裁剪拒绝/重试的RED→GREEN及最终源码/制品回归修复；无其他Critical/Important/Minor。此次决定仅交付CELT原生前置层，完整Opus/WebM、播放器trim/preroll、物理声音/同步、损坏/无索引扩展、跨设备、硬解重建、软解/缓冲预算和HDR约束验收仍开放，其代价是不能将解码制品通过视为播放器完整支持。

## 2026-09-29 AVC/Opus CELT 播放接入切片

起点 `ff095ef`。新增普通 Matroska VOD 的 CELT Opus 路由，限 OpusHead v1/family0、mono/stereo、48kHz。容器 CodecDelay/pre-skip 和 DiscardPadding 经桥接显式传入转换器；输出最大5760frames/120ms、输入64KiB，不依据不可信包duration分配。seek保留至少80ms可用解码历史，解码后在PCM层裁到原展示目标。seek(0)使用最早负PTS音频锚点，避免视频cue丢掉首包；native回归验证前后均192000frames，skip312、尾裁648。

候选制品独立五目标重建18规范项逐字节一致；接受lock哈希 `59e6077fbbaf84bcac30fb2514b3fade0b07f54513c41f21ef80b12014bd0694`。3slices/5architectures/37Swift symbols及3契约负例通过。没有新增FFmpeg模块，iOS15/macOS12下限不变。原生audio30、CELT源码/制品55884项断言与demux844项检查通过，video35/TS30/AVI88回归通过。Swift音频18项通过，包含首尾裁剪、完整/部分preroll、reset和不支持模式。

公开测试最初3条AVC/Opus均为decoder.audio_unsupported；接入后file/http/renamed-file均完成首帧、音轨选择、2s/1.25s/0 seek、结束与释放。独立错误测试发现新错误码未加入原生安全白名单，会退化为platform.failure；已加入固定文案，避免传播输入路径。失败事件与命令回执异步，测试等待原始失败事件；live源仍由既有容器策略先拒绝。

复审Important：现有音轨切换不为冷Opus decoder回退解码。此切片在任何渲染器/游标修改前明确拒绝切换到另一Opus轨（policy.opus_track_switch_unsupported），保留当前播放；混合AAC/Opus回归先观察到错误地成功，修复后验证拒绝、当前轨保留、seek继续及bounded下AAC仍可用。完整切轨预解码仍在待办。复审指出新增--only生成模式用rows[0]复制错误元数据；移除非必要的通用增量CLI，保留原有全量生成契约和新增Opus case，避免扩大生成器行为。

范围决定：SILK/hybrid继续拒绝；严格网络/缓冲/硬解策略下排除Opus并保留既有音轨，无可用音轨才返回policy.opus_unsupported。损坏/无索引Opus、非零时间原点广泛变体、物理声音/像素/同步、最低系统/其他设备/iOS/Android、硬解恢复/软件预算/HDR扩展均不作验收声明。Matroska毫秒时间基可能产生亚毫秒首包量化差，当前检查不等于端到端同步证明。代价是完整Opus/WebM与P03 Task1/Task2继续未完成。

混合策略夹具由既有原创AAC和Opus素材stream-copy生成，命令与哈希在资产opus-policy-fixture.json；它仅用于策略检查，不计入新增格式支持行。历史媒体与旧观测文件保留。

最终58项公开基线全部匹配：41条正常生命周期、12条有效素材支持缺口、5条损坏输入拒绝。旧55条原始观测逐项完全一致；旧17条素材记录不变。新增3条Opus严格播放要求均通过；4项公开策略/错误/候选失败保留/混合音轨测试通过，20项Dart错误测试、8项Python台账检查通过，静态分析无问题。Apple测试源对齐iOS658/macOS576。原始行及最终源/日志指纹见[macos-opus-playback-observations.json](../../../tool/media_matrix/macos-opus-playback-observations.json)。预期失败不计为支持成功。

复现（Flutter命令在packages/yl_player/example执行）：

```sh
flutter test integration_test/format_matrix_test.dart -d macos --no-pub --dart-define=YL_FORMAT_REQUIRE_SUPPORT=true --plain-name 'mkv-avc-opus /'
flutter test integration_test/opus_policy_test.dart -d macos --no-pub
flutter test integration_test/format_matrix_test.dart -d macos --no-pub
# 仓库根目录：
YL_TEST_FFMPEG_BUILD=<retained-signed-build> sh packages/yl_player_apple/tool/apple_ffmpeg/test_audio_codecs.sh
```

下一项优先补充Opus音轨切换所需的generation安全回退/预解码/首PCM时序；随后继续SILK/hybrid差异与其余格式缺口，不能把本次CELT子集等同完整Opus验收。

最终代码状态下macOS原生音频18+FEL管线3=21项全部通过，0失败/跳过；并非完整原生聚合门禁。独立复审问题已用失败回归和最终验证收束，无待处理Critical/Important；无需第二轮重复复审。

## 2026-09-29 Opus 活动音轨切换切片

起点 `49be730`。切入或切出Opus时复用既有seek事务：先准备候选音频转换器，再在主线程冻结位置/播放意图，暂停旧输出、推进generation、join demux并清空旧缓冲、回退游标、安装/reset音轨、重建video decoder并设置展示目标。预解码包恢复Opus历史，PCM在展示目标处裁剪。配置失败发生在破坏当前资源之前；相同音轨请求保持no-op。其他codec之间的切轨路径不变。

原生新回归先确认旧policy拒绝，然后使用真实Matroska demux/Opus转换器检查AAC→Opus、Opus→Opus冷decoder：至少80ms可用预解码、预解码期间不输出PCM、首PCM在目标后不足1ms、暂停位置/意图保留、旧video代次不可发布。还检查候选配置失败保持原轨/游标、游标变动后的取消不恢复不一致管线。VT和音频设备输出是受控依赖，不能把此测试当作物理设备输出证明。

加强时钟断言后发现进度分别落后目标9ms/19ms：音频管线用未裁剪的包PTS锚定媒体时钟。现在使用renderer归一到微秒的实际PCM位置及同一次sampleTime快照，避免裁剪/分批转换造成锚点偏差。RED→GREEN后38项托管生命周期、18项音频、3项FEL，共59项通过，0失败/跳过。

公开策略测试5项通过，包含本地暂停切轨/返回AAC、HTTP播放中AAC→Opus→AAC→Opus并保留播放状态与位置、后续seek到2.5s直至结束，以及既有严格策略/错误/失败候选保留。部署下限和FFmpeg制品未改变；原生资源与测试源同步到iOS/macOS，但本轮只有macOS运行证据。

新增native原创夹具 `opus_switch.mkv`：从上一轮 `mkv-avc-aac-opus.mkv` 按 `-map 0:v -map 0:a:0 -map 0:a:1 -map 0:a:1 -c copy` 生成；SHA256 `daf6eb2541db739f83df4b9f7394178414168fb21cf118993bd6bcae6620389f`。两条Opus轨复制同一信号，仅验证冷decoder/选择/时序隔离，不证明不同音频内容的听感辨别。

独立复审仅1项Important：未激活会话选轨只修改stream/generation，保留的旧renderer会拒绝新代次包。新增测试先观察到“不抛错、轨道被错误修改”，再在任何修改前明确拒绝未激活/已quiesce的Opus切轨；恢复播放后走活动事务。固定提示改为“Activate or resume playback before switching an Opus track.”，Dart消息回归先失败再修正。没有其他Critical/Important/Minor，不再重复派发复审。

范围决定：候选配置失败不影响当前播放；游标/缓冲已改变后的同代次取消安全终止当前会话，不能用旧decoder继续，需要重新加载。普通控制指令按FIFO排队，不会自行取消前一条；stop/deactivate/dispose及替换会撤销代次权限，旧操作不得终止新会话。未激活选轨保持拒绝，避免扩大到整套再激活重构。上述选择的代价是这些边界不承诺无缝恢复。完整SILK/hybrid、WebM、损坏/无索引变体、物理声音/像素/同步、最低系统/其他设备/跨端、严格资源与硬解保证仍未验收。

复审修复后原生39项托管生命周期+18项音频+3项FEL，共60项通过，0失败/跳过；5项公开策略/切轨测试和20项Dart错误提示测试再次通过。当前测试源/资源对齐iOS662/macOS580；这不是完整原生聚合门禁，也不构成iOS运行验收。

复现：在`packages/yl_player/example`执行公开测试；原生测试前先用`flutter build macos --debug --config-only --no-pub`恢复普通入口，避免使用上一轮集成测试入口。

```sh
flutter test integration_test/opus_policy_test.dart -d macos --no-pub
flutter test integration_test/format_matrix_test.dart -d macos --no-pub
flutter build macos --debug --config-only --no-pub
xcodebuild test CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES \
  -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:RunnerTests/YlManagedFallbackCharacterizationTests \
  -only-testing:RunnerTests/YlMacosAudioTests \
  -only-testing:RunnerTests/YlFELVideoPipelineTests
```

最终代码58项矩阵全部符合基线：41条完成正常播放生命周期、12条有效素材缺口、5条损坏输入拒绝，58条原始观测与上轮逐项一致。原始行、测试日志指纹和最终源文件哈希见[macos-opus-switch-observations.json](../../../tool/media_matrix/macos-opus-switch-observations.json)。本轮不修改媒体基线、FFmpeg制品或历史证据；下一项继续SILK/hybrid PCM差异，完整Opus与P03任务保持开放。


## 2026-09-29 Opus SILK/hybrid 解码切片

起点 `a87966c`。此前 FFmpeg 9.0.1 native Opus 桥接的 SILK PCM 差异，本轮用宿主 FFmpeg 8.0.1 独立解码也复现：相对宿主 libopus 参考原始 SNR 13.02 dB，最佳移动两采样后仍仅 39.96 dB，低于既定 50 dB 门槛。差异存在于独立解码器对照，不能通过改变播放器 trim 或降低门槛处理。

范围决定：使用官方开源 libopus 1.6.1（BSD）替换 FFmpeg native Opus，移除不再需要的 swresample；不接入商业 SDK。固定官方源码 URL/SHA256、原样保留 COPYING，在五个 Apple 目标中静态链接并隐藏内部符号。仅启用可重建的标量实现，SIMD/汇编/运行时分派及可选神经扩展关闭；性能与长时间功耗仍需后续测量。代价是新增开源依赖及构建维护责任。

桥接现在接受 SILK、hybrid、CELT；范围仍为 OpusHead v1/family0、mono/stereo、48kHz。libopus 处理有符号 Q8 增益，reset 保留增益；容器继续显式持有 pre-skip/CodecDelay/DiscardPadding，不能重复裁剪。120ms/5760frames、64KiB 输入上限、先校验容量和裁剪再消费解码器的规则不变。活动音轨切换继续走上一切片的 generation/seek/preroll 事务；未激活切轨和严格网络/缓冲/硬解策略限制不变。无效帧计数返回 `decoder.audio_opus_failed`，不再把 SILK 伪装成“不支持模式”；header/mapping/channel 问题继续返回 `decoder.audio_opus_unsupported`，原生和 Dart 固定提示去掉过时 CELT 限制。

新候选制品两次独立五目标构建的18个文件/链接项逐字节一致，接受 lock SHA256 `058933a10c65ebecc3e938102c95184e7f808ca9444519c66f745d6b277f95ea`。3 slices、5 architectures、37 Swift 消费符号通过；源码/配置/许可证/二进制篡改和错误 Opus 源码归档共5个负例均以预期原因拒绝，校验不改写 lock。FFmpeg 保留原签名验证；Opus 使用固定官方归档哈希，未声称有 detached signature。iOS15/macOS12 下限不变。

原生源码与最终制品的32轮夹具检查共162876项断言通过。覆盖 CELT 2.5/5/10/20/40/60/120ms、SILK 10/20/40/60ms及窄/中/宽带、hybrid 10/20ms、mono/stereo、header增益、reset、跨包skip、尾裁与无效输入；每条4秒样本输出192000frames，PCM门槛仍为50dB。受控编码器通过同一个解码器执行 SILK→hybrid→CELT→hybrid→SILK，实际TOC包含三模式和四次切换，与独立解码状态逐样本一致。参考使用独立安装的宿主libopus，验证桥接与裁剪正确性，不是独立解码算法一致性的证明。

新增两份原创 Matroska/AVC/Opus mono 夹具：SILK 为67包config11；hybrid夹具包含20包config15和181包config31，一次真实hybrid→CELT切换。低比特率立体声编码会内部降混，因此公开素材使用单声道原始tone，避免把混合音调当作声道标记；原生双声道PCM对照另行覆盖。旧18份矩阵素材不变，新增素材均通过独立宿主解码的原有颜色/频率门槛。生成命令、ffprobe、哈希及逐包模式统计随新证据记录。

源码/制品 audio30、demux844、video35、TS30、AVI88和FEL回归通过。macOS原生39项托管生命周期+18项音频+3项FEL共60项通过，0失败/跳过；Dart错误20项通过，Python台账8项通过，Apple测试源对齐iOS662/macOS580。独立一次复审未发现Critical/Important/Minor；没有重复派发复审。

公开策略/错误/切轨5项及新增SILK/hybrid的6条严格公开播放路径均通过：file/http/renamed-file，各自验证首帧、音轨选择、2s/1.25s/0 seek、结束和释放；对应集成代码静态分析无问题。完整矩阵最终结果与源/日志指纹见后续本节记录。以上不是完整P03或完整Opus/WebM验收：mapping family非0、多声道、Vorbis、VP9/AV1视频、物理声音/像素/同步、跨平台设备和最低系统、严格资源策略与长期性能仍待完成。


最终64项格式基线全部匹配：47条正常播放生命周期完成、12条有效素材仍有支持缺口、5条损坏输入明确拒绝。原有58条原始观测逐项完全一致；旧18份素材及其元数据未变。只有新增6条已实测通过的SILK/hybrid预期加入baseline，未将历史失败改为成功。完整观测、逐包模式统计、PCM结果及源/日志指纹见[macos-opus-modes-observations.json](../../../tool/media_matrix/macos-opus-modes-observations.json)。首次严格筛选因新ID尚未加入静态用例目录而未执行任何测试；补齐目录后6项严格测试与64项完整矩阵均实际运行通过，空跑不计数。

复现（Flutter命令在packages/yl_player/example执行）：

```sh
flutter test integration_test/opus_policy_test.dart -d macos --no-pub
flutter test integration_test/format_matrix_test.dart -d macos --no-pub --dart-define=YL_FORMAT_REQUIRE_SUPPORT=true --name 'mkv-avc-opus-(silk|hybrid) /'
flutter test integration_test/format_matrix_test.dart -d macos --no-pub
```

原生制品/PCM复现使用上文`test_audio_codecs.sh`、`test_video_metadata.sh`、`test_build_contract.sh`；`YL_TEST_FFMPEG_BUILD`须指向本轮包含`opus-stage`的固定源码构建目录。网络不可用时提供固定的`YL_FFMPEG_ARCHIVE`、`YL_FFMPEG_SIGNATURE`及`YL_OPUS_ARCHIVE`。下一切片继续Vorbis或VP9/AV1视频缺口，P03 Task1/Task2仍开放。
