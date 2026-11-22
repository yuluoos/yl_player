# 小米电视 Android 播放专项验收

设备为小米 MiTV-MTTP0，Android 9 / API 28、32 位 ARM。测试源码为 `a1363b86`。各入口使用各自的 Debug APK，逐次核对设备安装包与构建产物的 SHA-256。下表按业务用例计数，剔除 Flutter 框架收尾。测试结果独立于已完成的同包 40/40 格式矩阵。[逐组结果](evidence/2026-11-22-android-mitv-remaining-acceptance/results.json) · [设备回执、请求与逐帧日志](evidence/2026-11-22-android-mitv-remaining-acceptance/captures.tar.xz)

本轮重现了三处可以分别排查的问题。电视 AVC 解码器在逐帧采集时释放输出缓冲失败，多 Period 视频选轨被策略拒绝，直播低延迟暂停恢复在 HLS 和 HTTP-FLV 上未通过。25 秒停供和独立 RTMP 源的结果见各场景回执。

## DASH 音画与资源

| 原生用例 | 真机结果 |
| --- | --- |
| DASH 严格逐帧音画 | 首个 AVC 片段在 `OMX.MS.AVC.Decoder` 的 `MediaCodec.releaseOutputBuffer` 抛出 `IllegalStateException`。未产生可配对帧，无法计算偏差。 |
| DASH 前台重建与跨段推进 | `YlFixedVideoTrackSelector` 选轨返回 `POLICY_UNSUPPORTED`，未完成重建验收。 |
| 原生帧预算耗尽后释放、实际引擎单次终态后清理 | 2/2 通过。 |
| `YlDashDnsInstrumentedTest` | 2/2 通过，0 项失败。 |
| `YlDashPcmInstrumentedTest` | 8/8 通过，0 项失败。 |
| `YlDashJointInstrumentedTest#nativeJointBaseline` | 0/1 通过，1 项失败。 |
| `YlDashLifecycleInstrumentedTest` | 0/1 通过，1 项失败。 |

多 Period 节目的 19 项和延迟重配置的 2 项都返回了 `policy.unsupported`。原生日志显示 `YlFixedVideoTrackSelector.selectAllTracks` 选轨失败。单独的固定画质跨段入口使用另一组媒体，播放及回退规则通过。

公开接口的双会话停止、复开和旧会话隔离通过。两个会话均停止后，5 次系统采样的视频解码器计数范围为 0–0。

## 弱网点播

| 场景 | 设备与服务端观测 |
| --- | --- |
| 120 秒限速再恢复 | 播到片尾，末次位置 120.000 秒。公开画面尺寸为 180p → 360p。三阶段媒体字节为 67625 / 402827 / 6114253。未满足先高、后降、再升的完整判据。 |
| 120 秒限速再恢复（复测） | 播到片尾，末次位置 120.000 秒。公开画面尺寸为 180p → 360p。三阶段媒体字节为 104113 / 385349 / 6095243。未满足先高、后降、再升的完整判据。 |
| 40 秒素材、停供 25 秒 | 未播到片尾，末次位置 4.023 秒。公开画面尺寸为 180p。三阶段媒体字节为 138236 / 0 / 0。 |
| 40 秒素材、停供 25 秒（复测） | 未播到片尾，末次位置 4.014 秒。公开画面尺寸为 180p。三阶段媒体字节为 138236 / 0 / 0。 |

## 直播

| 协议与模式 | 框架结果 | 最后阶段 | 离线回放 |
| --- | --- | --- | --- |
| HTTP-FLV · 固定低延迟 | 通过 | baseline | 143 个样本，完整 |
| HTTP-FLV · 固定流畅 | 通过 | baseline | 143 个样本，完整 |
| HTTP-FLV · 流畅 → 低延迟 → 流畅 | 未通过 | low-resume | 177 个样本，未通过完整性或行为判据 |
| HLS · 固定低延迟 | 通过 | baseline | 143 个样本，完整 |
| HLS · 固定流畅 | 通过 | baseline | 143 个样本，完整 |
| HLS · 流畅 → 低延迟 → 流畅 | 未通过 | low-resume | 177 个样本，未通过完整性或行为判据 |
| RTMP · 固定低延迟 | 通过 | baseline | 143 个样本，完整 |
| RTMP · 固定流畅 | 通过 | baseline | 143 个样本，完整 |
| RTMP · 流畅 → 低延迟 → 流畅 | 通过 | stop | 193 个样本，完整 |

首次 HLS 模式切换遇到电视关闭，重连时应用进程和端口转发均已消失。该轮只保留中断记录，表中使用重连后的独立运行。直播时序取自公开播放器状态，未测外部采集端到电视屏幕的延迟。

## 公开接口用例

| 项目 | 通过 | 失败 |
| --- | ---: | ---: |
| HTTP 403、重定向预算、损坏字幕隔离 | 3 | 0 |
| 重叠播放与解码器释放 | 1 | 0 |
| DASH 多 Period 节目 | 0 | 19 |
| DASH 延迟重配置期间取消或替换 | 0 | 2 |
| DASH 固定选轨跨 Period | 1 | 0 |
| DASH SegmentBase | 0 | 2 |
| 公开音轨选择 | 2 | 0 |
| 双播放器回退 | 1 | 0 |
| 会话替换 | 3 | 0 |
| 渐进播放及前后台恢复 | 2 | 0 |
| RTMP 独立对端及故障恢复 | 0 | 6 |
| RTMP 十分钟持续播放 | 0 | 1 |
| 系统 DNS、RTMP 握手错误 | 2 | 1 |
| DASH 请求、凭据与停止 | 6 | 0 |
| DASH 视频空隙字幕 | 3 | 0 |
| DASH 候选源重试 | 0 | 3 |
| 脚本运行时 | 9 | 0 |
| 九份替代脚本行为 | 9 | 0 |
| 脚本向 RTMP 播放器交接 | 0 | 1 |

独立对端的 6 个故障用例及十分钟长播用例均在准备播放时返回 `decoder.unsupported`，长播没有进入计时窗口。该入口显式使用 `systemDefault`，单独通过的直播模式入口使用播放器默认的 `hardwarePreferred` 并声明直播与 FLV。此次记录无法单独确定哪个参数造成差异。

**系统 DNS**　电视联网时对保留域名的系统查询返回失败。RTMP 握手提前关闭和 DASH 清单 DNS 错误映射通过。分段用例实际返回 `policy.unsupported`，未到达预期 DNS 错误；注入传输层 DNS 故障的两个原生用例均通过。

**脚本**　九份替代脚本的行为与媒体交接通过 9/9。框架结束后，系统资源服务记录同一进程持有 0 个视频解码器。九份冻结原件仍缺归档，原件兼容性继续待验。

脚本 RTMP 交接首次在设备上返回 `decoder.unsupported`，启动器漏传失败退出码。修正启动器后独立补验得到相同的设备错误，对端记录退出码 1、连接清理完成。该项计为一次失败。

原始归档 SHA-256 为 `a5e915c8317e2db7c886e9048b472f54b95f593dca023daafbdd99dd3fe66c27`。[逐文件哈希](evidence/2026-11-22-android-mitv-remaining-acceptance/results.json)
