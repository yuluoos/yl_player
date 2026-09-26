# Apple DASH 加载时严格视频上限

前一阶段跨 Period 自动路径已提交为 `d1b5b65`。用户要求提交后继续；本阶段推进 REQ-05 的独立上限约束，并兑现清楚、脱敏的错误信息。不接商业 SDK，不改变 PD-01；PD-02/03 仍未确认。沿用当前 `codex/fel-integration` 工作区，完成后保留新改动供后续提交。

## 范围与依据

当前 `preferredPeakBitRate` / `preferredMaximumResolution` 是偏好，不能作为严格选轨保证。Apple 官方明确说明无法满足码率偏好时仍会继续播放，参见 [preferredPeakBitRate](https://developer.apple.com/documentation/avfoundation/avplayeritem/preferredpeakbitrate) 和 [preferredMaximumResolution](https://developer.apple.com/documentation/avfoundation/avplayeritem/preferredmaximumresolution)。现有 active AV→AV 安装会先移除旧 item，恢复位置可能是旧保存值，并清除播放意图；它不是可直接复用的运行时质量切换事务。

因此先交付完整的**加载时上限**：DASH 的每个 Period 都必须有满足所有独立约束的候选，生成清单只包含这些候选，解码尺寸在输出前再次检查。支持显式 DASH 和 automatic `.mpd`，当前静态明文 AVC/AAC 子集。清晰度限制在该次 Load 内不可改变；相同值幂等成功，任何不同值（包括清空）同步明确失败，不能保存未执行的意图或影响恢复。要改变限制，使用现有 Load options 重新加载。

运行时无缝修改、固定选轨、档位缺失后的固定→自动状态、完整弱网 ABR 仍是已接受的后续目标，需要独立的 item 事务和有效选轨状态；本阶段不声称完成它们。普通 HLS/MP4 的现有偏好行为不在本阶段改写。

## 投影与边界

`YlDashHlsCompiler.compile` 增加默认 unconstrained 的内部 `videoConstraints` 参数。未设置任何限制时保留已提交行为。存在限制时先验证原始整个节目（不能用过滤掩盖不兼容轨道）：采用变化家族的保守声明检查，同 AVC codec/Profile（66/77/88/100）、角色、显示比例、规范化声明帧率、仅缺失或1:1 SAR，无颜色/动态范围/SupplementalProperty 声明；质量元组无歧义，整个节目最多16个身份。

限制取交集：`width <= maxWidth`、`height <= maxHeight`、`bandwidth <= maxBitrate`（仅有值的字段）。maxBitrate 是 MPD 声明的视频 Representation 带宽，不是视频加音频总量，也不是测量的瞬时网络速率。宽高为声明的方形像素尺寸；真实输出的显示尺寸还必须符合上限。

先验证全部、过滤每个 Period，再用现有完整自动路径规划。任一 Period 无候选，则在 manifestURL/mediaURL closure 调用前以 `decoder.quality_constraint_unsupported` 失败，不能用原先“无较低档则取最小档”的规则越过硬限制。所有原解析、URI、段、清单注册表预算与最严格凭据传播保持；无约束旧域包括单档带宽变化保持。过滤不能产生跳过 Period、剪短时间轴或重复音频。

约束值仍为正 Int32 范围；保持现有无效参数错误。质量策略错误保留可识别安全 code，但不能返回 injected closure 的错误原文、URL 或头。新增 `policy.video_constraints_reload_required`，固定公开提示要求以新上限重新加载；为已有 `decoder.quality_constraint_unsupported` 增加明确公开说明。

## 生命周期与输出

将同一不可变有效约束从 Load 准备传到 prepared asset、loader、compiler 和 AV backend。普通首次加载使用该次 options；legacy nil options 继承必须在主线程明确捕获，不能后台读取后来变化的字段；恢复必须继续使用已接受约束。取消或失败不能发布旧候选或改变旧会话约束。

在任何实际像素缓冲对外发布/返回前检查 DASH 的实际显示几何（包括宽高、PAR、旋转处理）。超出限制或无法证明请求的尺寸限制满足时，禁止该帧进入 texture/native surface/firstFrame；产生脱敏的 `decoder.quality_constraint_unsupported` 会话失败并停止继续输出。检查必须覆盖 `copyPixelBuffer` 的直接返回路径，不能仅检查事件里的尺寸。无 DASH 约束不改变既有输出。

运行中不同约束使用上述 reload-required 命令错误，在修改 backend / coordinator accepted constraints 前拒绝；活动、暂停、失活/待恢复、恢复中均不得把拒绝的值保存为已接受意图。相同值成功；Stop 清除会话限制。新 Load 自己的 options 可以改变上限；失败 Load 保留旧会话、旧限制和可继续播放性。恢复/重开不能把原过滤清单换成无约束清单。

## 验收

原生：上限独立与交集、边界相等、码率只算视频、跨段增删与空候选、原不兼容轨道不能被过滤掩盖、零 URL emission 失败、凭据与预算、无约束兼容。验证 loader 实际转发及取消，接受意图/恢复策略、相同约束和变更/清空拒绝、Stop/new Load 重置；真实 CVPixelBuffer 几何拒绝，异常帧无输出。canonical Swift 与 iOS/macOS 镜像/current inventory 同步，历史清单不改。

公开播放器在 macOS 与 iOS Simulator 各跑单文件四例：
1. 原多档两 Period 在 maxWidth320/maxHeight180/maxBitrate350000 下只输出320×180；自然跨段、seek5后5.5～8秒、seek1后1.5～4秒、完成；实际请求没有高档init/chunk，自动状态不变。
2. 先播放正常旧会话，再 Load 高→低清单配180上限：首段无候选，新 Load 明确失败且无候选媒体请求，旧 session 继续推进。
3. 已受限会话相同上限幂等成功；改为更严和清空均 reload-required，既有会话/输出继续，随后通过新 Load（高→低无上限）观察640×360，证明不会错误保留旧限制。
4. 清单声称320×180而使用已有640×360编码字节，设置180上限：不得发布该会话 firstFrame；明确会话失败，不泄露地址/凭据。

只运行覆盖改动的原生/Dart测试和这四个公开用例，平台串行；无生产Android改动不重复Android矩阵。记录实际工具警告、设备、命令、结果。恢复自有模拟器状态及四个 Flutter target 配置。独立任务复审和一次整阶段复审；同一轮修复合并处理已知问题。
