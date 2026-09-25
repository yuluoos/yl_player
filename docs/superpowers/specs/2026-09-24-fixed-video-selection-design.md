# 固定视频档位与缺档回退：第一实现阶段

依据已确认需求 REQ-04/05/13、[ADR 0007](../../adr/0007-missing-fixed-quality-returns-to-auto.md)。用户已授权提交上阶段后继续。上阶段已提交：yl_player `9f6b490`，tvs `9c183fd`，均未推送。

本阶段交付统一可观察的自动/固定控制，以及 Android Media3 的实际固定选择和跨 Period 缺档回退。Apple 固定选择、Apple 动态梯度以及三端完整 CAP-ABR 仍须继续实现；这是工程分阶段，不削减已确认产品目标。不接入商业 SDK。

## 公开语义

`YlPlaybackSession.selectVideoTrack(String? trackId)`：非空 ID 来自当前会话 `state.videoTracks`，null 回到自动。独立的 `setVideoConstraints` 上限保持有效。命令接收不等于画面已切换，状态才是模式权威；`videoTracks.isSelected` 仍沿用原有轨道语义，不拿它证明当前像素尺寸。

新增不可变 `YlVideoSelection`：`fixedTrackId` 为 null 表示自动，非空表示固定；`reason` 为 `initial`、`user`、`trackUnavailable`，`isAutomatic` 为派生属性。默认 initial/自动，固定态只能 user；退出固定因缺档标记 trackUnavailable，后续快照保留原因直至显式选择或新会话。ID 在字符串表示中脱敏。

新增 `YlPlayerState.videoSelection`（默认自动），参与 copyWith/equality/hash/toString/边界验证。固定 ID 必须对应当前视频轨道；自动模式不得携带固定 ID。若短暂轨道列表为空，不能当作已确认缺档；在该过渡期间保留上次已确认的轨道列表与模式，不发布固定ID悬空的快照，新固定命令则须由内核按实际当前可用轨道再次校验。新 load/stop 重置为自动，旧会话命令仍按原契约拒绝。

为保持既有 SPI 实现源兼容，增加可选接口 `YlVideoTrackSelectionPlatformPlayer`；只有实现者并声明 `YlPlayerOperation.videoTrackSelection` 才能接收命令。其余后端命令明确以安全的 unsupported/command 失败，不能默默降为上限或返回成功。Apple 本阶段不声明能力，无需新增无用途的原生通道。

## Android 路径

Pigeon 增加 nullable track ID 命令、经过校验的模式原因字符串（initial/user/trackUnavailable）和完整状态字段；新wire类追加于所有旧类之后，保留工厂消息codec标签以便真实旧版请求到达版本门槛；同步生成 Dart/Kotlin，Android wire schema 3→4，握手防止混用旧二进制；SPI major 保持2。既有 delta 仅更新位置/指标时必须保留模式。所有入口继续遵守当前会话、worker 所有权和命令确认边界。既有 Android `setVideoConstraints` 改为等待实际 worker 校验完成再确认，冲突不能先成功后后台失败。处于释放/恢复租约的过渡时，约束及固定选轨命令明确以 `resource.exhausted` 拒绝且不修改策略，调用方须在恢复活动后重试。

固定选择使用 Media3 `TrackSelectionOverride` 单一轨道，不通过最大码率模拟。先验证轨道支持、host 上限、设备 envelope 与既定解码策略；未知的约束字段不能当成已满足。固定不允许健康策略/带宽回退改为更低档位。约束更新若排除固定档位则明确拒绝，不清除固定、不放宽约束。

固定身份必须在原生为每个 Period 选择轨道时生效，不能只在 `onTracksChanged` 后补救。预缓冲下一 Period 不得提前改变当前公开模式；公开回退须等权威当前 Period 确认。Media3 的保护级选择扩展点可用于实现该边界，具体签名以锁定1.11.0产物核验；参考 [DefaultTrackSelector 官方 API](https://developer.android.com/reference/androidx/media3/exoplayer/trackselection/DefaultTrackSelector)。

跨 Period 使用独立于 Representation ID/XML 顺序的质量身份：至少包含编码、分辨率、码率、帧率、角色及颜色/动态范围信息（以当前原生格式报告为边界）。身份相同则重新绑定新 TrackGroup 的单轨覆盖；不可仅用同分辨率或同 ID 判断。身份歧义不能任意选择。当前权威 Period 内已确认不存在固定身份时清除 override，进入自动并保留其他上限/硬解/画质限制。弱网、暂停、缓冲或暂空轨道不触发缺档。

本阶段固定路径保守纳入兼容 AVC/SDR 梯度；明确不兼容编码/动态范围时失败，不借 PD-01 静默授权 HDR/SDR 转换。应沿用已有错误分类并输出稳定安全原因。恢复/回滚保持当前会话模式，replacement/stop 清除；不把上一源偏好泄漏给下一源。

## 验证

Dart：模型/验证、stale/非法 ID/unsupported 命令、状态全量与 delta 保留、wire roundtrip和schema拒绝。Android：真实 selector 单轨覆盖、同语义重排重新绑定、缺档自动一次、缓冲不降档、cap冲突拒绝、过期事件/恢复/替换边界。保留有意义 RED→GREEN 证据。

受控 Android 公共播放：复用已编码 AVC 两档夹具。先验证两个 Period 均有高档但 ID/顺序变化时持续固定高档；再用第二 Period 缺高的清单，观察实际高档画面及跨段后自动低档、统一时间轴和seek/stop。这不代替弱网轨迹、设备矩阵或长期性能。若设备门槛受阻，要给出实际错误与未验收边界，不计通过。Apple只需证明命令诚实拒绝及既有Dart适配兼容；无生产Swift改动则不重复Apple设备测试。
