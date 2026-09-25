# 固定视频档位与 Android 缺档回退 Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development. 保留当前功能分支。用户授权提交的是上一阶段；本阶段不自动 commit/push。实现任务依次执行，使用独立任务复审和一次整批复审。

**Goal:** 提供可观察的固定/自动视频档位 API，在 Android 实际锁定档位并按 PD-01 缺档回到自动。

**Architecture:** 可选 SPI 接口保持旧实现兼容，Android Pigeon 同步 schema4，原生 Media3 selector 执行单轨覆盖，语义身份跨 Period 重绑或可观察退回自动。Apple 明确不声明固定支持。

**Tech Stack:** Dart/Flutter、Pigeon28、当前锁定 Media3/Kotlin；无新依赖、无商业 SDK。

**Spec:** `docs/superpowers/specs/2026-09-24-fixed-video-selection-design.md`、需求 REQ-04/05/13 和 ADR0007。

## Global Constraints

- 保留 Android API24、iOS15、macOS12 下限；基线9f6b490；tvs9c183fd本阶段不编辑。
- 固定弱网不得降档；缺档回自动不得解除独立上限、硬解或画质限制。
- 不能用相同分辨率/Representation ID认定同一档位；颜色/编码不兼容不能借回退绕过。
- 不泄露原始地址、请求头、轨道原始文本到错误/日志；旧会话/旧事件不能变更当前状态。
- 无能力后端须明确unsupported，不可模拟成功；Apple暂无固定接口实现不等于三端目标取消。
- 原生构建/设备串行；采用必要定向测试，不运行无关完整设备矩阵。

## Review Focus

1. Media3 override可以绕过普通selector上限，固定前与上限更新必须明确验证。
2. onTracksChanged重复/暂空/提前read-ahead不能错误触发PD-01，必须以权威当前Period为准。
3. 弱网健康策略、恢复与rollback不得无声清除固定；replace/stop不得继承前源固定。
4. 相同ID但不同码率/codec/颜色、不同ID但相同档位、重复语义轨道均要明确匹配或拒绝。
5. 新状态不能被位置delta抹掉；schema不一致须在创建握手处失败。

## Task 1: 公共契约与 Android 通道

**Files:** `packages/yl_player_platform_interface/lib/src/model/video_selection.dart`（新增）、`player_state.dart`、`capabilities.dart`、state validation、exports、可选SPI文件；`packages/yl_player/lib/src/playback_session.dart`、exports；Android pigeons/生成输出、Dart transport/player/codec、native session/models通道接线；相关Dart/native契约测试。

**Interfaces:** `YlVideoSelection({String? fixedTrackId, YlVideoSelectionReason reason = YlVideoSelectionReason.initial})`，`enum YlVideoSelectionReason { initial, user, trackUnavailable }`，`bool get isAutomatic`；`YlPlayerState.videoSelection` 默认 `const YlVideoSelection()`；可选 `abstract interface class YlVideoTrackSelectionPlatformPlayer { Future<void> selectVideoTrack(YlPlaybackSessionId sessionId, String? trackId); }`；session `selectVideoTrack(String? trackId)`；capability append `videoTrackSelection`。Android `AndroidVideoSelectionMessage` 使用 nullable `fixedTrackId` 与经过校验的 reason 字符串（initial/user/trackUnavailable），新wire类型追加在全部既有类型后以保持工厂codec标签；`AndroidVideoTrackCommand(sessionId, trackId?)`，async `selectVideoTrack` host method；既有 Android `setVideoConstraints` 同步改为 async/suspend ACK，以便实际约束冲突可返回给调用方。AndroidStateMessage末尾新增 nullable videoSelection（native总是发出，decoder拒绝缺失schema4有效state），wire schema4。

- [x] 写RED：自动/固定statecopy和验证，stale/非法ID、未实现可选SPI的Apple/fake明确unsupported，Android命令和snapshot/delta模式保留，schema3握手拒绝。
```dart
expect(const YlVideoSelection().isAutomatic, isTrue);
expect(state.copyWith(videoSelection: const YlVideoSelection(fixedTrackId: 'v0', reason: YlVideoSelectionReason.user)).videoSelection.fixedTrackId, 'v0');
await session.selectVideoTrack(null); // auto, no constraint mutation
```
- [x] 实现契约、验证与映射；Android native coordinator命令采用现有acceptedCommand；engine默认明确unsupported，Task2覆盖真实执行。Task1不提前声明Android能力，Task2开始支持才声明。Native状态默认明确initial/自动；旧媒体load/reset完整保留语义。不得手改Pigeon生成输出。
- [x] 运行受影响Dart包测试/分析、Android Pigeon drift与必要编译；若native行为留给Task2，用最小编译/契约证明通道可构建。记录精确命令/结果。
- [x] 自检、报告和独立任务复审；不提交。

## Task 2: Android 固定执行与 Period 回退

**Files:** `YlMedia3Core.kt`、新的紧凑video-selection policy、`YlMedia3Engine.kt`、`YlManagedAndroidEngine.kt`、`YlSessionCoordinator.kt`、session models及对应JUnit/Mockito tests；必要safe errors。

**Interfaces:** 使用Task1可选接口、wire及state；原生single-track override只接受当前有效轨道，state包含已接受模式；默认auto。内部恢复点需携带固定选择身份并在恢复时验证，不能通过原来的selectedVideoTracks假装固定。

- [x] 写RED验证单轨固定、同语义跨Period重绑、缺档自动、重排/ID变化、相同分辨率不同编码/码率拒绝误配、duplicate ambiguity、暂空track/buffering不降档、cap冲突、stale/stop/replacement/rollback。
```kotlin
// Use real Media3 TrackGroup/Format and DefaultTrackSelector parameters.
// fixed override must contain exactly one requested track index;
// new current Period missing that semantic format must clear override
// and publish fixedTrackId=null, reason="trackUnavailable".
```
- [x] 实现可测试的语义身份/约束策略、selector接线与生命周期同步。supported能力仅Media3可执行；managed wrapper转发能力/选择，managedFallback明确unsupported；固定期间不得自动换到不能维持该固定身份的fallback，须明确失败。固定时禁止健康策略码率降档，其他恢复与硬解策略保留。
- [x] 执行聚焦native policy/coordinator/Media3回归及编译。以RED→GREEN说明至少一条真实错误；交付稳态代码与报告。
- [x] 独立任务复审；不提交。

## Task 3: 公共播放验收与文档

**Files:** `packages/yl_player/example/integration_test/android_video_selection_test.dart`，既有 `support/dash_server.dart` 仅必要扩展；夹具目录增加可审计缺档MPD（复用既有媒体字节），对应资产声明；`docs/platform-support.md`、`docs/transport-compatibility.md`、阶段报告。

**Interfaces:** Task1公开session/state，Task2实际Android能力；从state.videoTracks取高档ID，不猜内部编号。

- [x] 编写两个公开播放用例：原有MPD两个Period均有高档但ID/顺序变化，固定高档后首次确认高档画面，再收集到跨段后的全部状态，断言未出现低档geometry且固定模式不变；新增MPD第一Period两档、第二Period缺高，验证实际高档画面后自然跨段自动低档、reason、时间轴、seek与stop。保持已有静态同梯度Apple夹具不变。
```dart
final high = controller.state.videoTracks.singleWhere((t) => t.height == 360);
await session.selectVideoTrack(high.id);
// Observe native state fixed, real video height 360, then after boundary
// automatic/trackUnavailable and real height180; do not infer from command ACK.
```
- [x] 运行必要Dart回归与Android单个目标文件的两个设备用例，保留log/所用设备ID/真实观测；已有Apple生产代码未变不重复其播放矩阵。
- [x] 更新精确支持声明（Android首实现、Apple明确unsupported、固定规则尚不等于完整ABR）；报告实现/实测/未验收边界。更新当前传输文档为Android schema4 / Apple schema3 / public SPI2，说明真实旧工厂消息仍可解码到版本拒绝；保留历史阶段报告的原始版本记录。任务复审与整批复审。

## 完成边界

交付可用的Android固定档位/缺档回退和统一公开契约；Apple固定及动态梯度、业务UI、通用DASH、弱网ABR定量与真机矩阵继续保留。若实际native契约无法满足约束，明确失败并记录，不以静默降档充数。
