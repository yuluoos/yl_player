# P03 工程收尾与 iPhone 证据（2026-10-20）

按已批准设计完成本轮工程范围；完整 P03/CAP 验收仍开放。基线 `db769ffd`，分支
`codex/p03-engineering-completion`。最终源码指纹见 [source-identity.json](source-identity.json)，
最终机器核对见 [final-verification.json](final-verification.json)。仅本地提交，未合入主工作区。

## 最终同构建 iPhone 结果

设备 iPhone 16（iPhone17,3），iOS 27.0 / 24A437。固定构建 SHA-256：
`47622b5de5acca89f19f49d0e1f3ea67229542531796bbf8d878169df5f1dcc4`。安装包、实际加载镜像、媒体、run/session 及框架终态均验证。

| 固定范围 | 结果 | 证据 |
| --- | --- | --- |
| E-AC-3、DTS、FLAC、WebM/Vorbis、AC-3 5.1、PS/AVC 六控制 | 严格音画 6/6 | [结果](device-final-controls/result.json) |
| AV1/Opus managed HTTP | 严格音画 1/1 | [结果](device-final-av1-http/result.json) |
| HEVC Main10/AAC managed HTTP | 严格音画 1/1 | [结果](device-final-main10-http/result.json) |
| AVPlayer 本地 MP4 | source-pull 1/1；严格消费门禁保持 false | [结果](device-final-avplayer/result.json) |
| 错误构建身份 | 播放前拒绝；完成所属应用清理 | [结果](device-final-negative-identity/result.json) |
| 框架末尾故意失败 | 原始音画通过仍拒绝总体通过；清理成功 | [结果](device-final-negative-framework/result.json) |

通过项包含真实附着显示层像素、PCM 标记、播放/完成、1250ms/2250ms/0ms seek 和释放。
八个严格单元是本轮选择范围，不能填成完整 40/40，也不能拼接其他构建的通过项。
AVPlayer 的 `renderPullAcceptance=true` 不提供硬件播放头；其 CLI 退出 1 是保留
`played_sample_clock_unverified` 的预期结果。普通 Debug/Release 不启用这些观察器。

## 工程修复与回归

- 新增物理设备冻结采集：显式 UDID、真实设备校验、一次性有界计划、无 hot 同步、
  UUID/应用容器固定路径、新鲜拷贝、原始数据及所属 app.stop 成功回执。
- 采集器必须完整结束；已有成功状态不能跨越启动超时或进程提前退出被误算通过。
  真实验证器参与的回归先 RED 后 GREEN。
- 活动网络 seek 暂时释放 VT 解码器时，play 不再启动竞争的网络重建；后续命令按 FIFO
  执行。原 iPhone Main10 HTTP 两次同包失败保留，新包完整通过。
- 未激活会话的已确认 seek 通过同步意图路径保留位置；切轨仍保持原有活动状态/取消
  校验。扩展测试的原断言全部保留；两项占位网址改为自有 MP4，避免真实 TLS 干扰。
- 独立 iPhone 验收入口使用已有 pluginManagedMediaPlayback 音频所有者，解决原
  appManaged 无宿主配置时 AudioQueue CannotStart（-66681）。
- tap 中 0 帧且起点/时长均无效的请求只保留诊断，不推进时间也不抹掉已有 PCM；
  有帧或媒体区间的错误仍使证据失败。真实 Swift 存储测试先失败后通过；数字错误链
  和最多八个拒绝记录有界保存，音频回调不分配诊断数组。
- Vorbis 安全消息与既有最多 4096 样本 CodecDelay 能力对齐。

最终媒体工具 80/80（含真实 Swift 一次性文件和 PCM 存储）、decoder 工具 21/21；
受影响原生两批 48/48、23/23，均零失败/跳过；Dart codec 20/20、bound source/cleanup
3/3，最新 example analyze 无问题，公开表面检查通过。普通 Debug 三个产品镜像未包含
bound plan/probe/audio observer 符号。新 iPhone 构建成功。各批原始输出在 [logs](logs)，
原生结果见 [native-summary.json](native-summary.json) 与
[restoration-verified-summary.json](restoration-verified-summary.json)。这些是分批检查，
不描述为同一次全工程/三端发布测试。

## 失败历史、复审和裁定

全部 `device-*` 目录保持各自原始 build/run 身份。最初 hot 控制仅作历史；最终使用
`--no-hot --use-application-binary`。旧 Main10 HTTP 两次失败、AVPlayer AudioQueue
启动失败、空 tap 请求误拒绝、基线三项原生失败和一次过宽分派修复均保留。
`flutter.log.gz`、`rows.json.gz`、`unfinished.json.gz` 可直接解压；未用修复结果覆盖失败。

唯一最终独立复审检查 `db769ffd..30359762` 全部十个文件，结论 With fixes；1 项
Important（采集超时误接受），无 Critical/Minor。该问题已 RED→GREEN 和完整工具套件
闭环。运行中新定位的 seek/audio 问题由主执行者按原生/真机对照完成，不宣称复审者
审阅了之后的所有改动，也未派发第二次复审。完整执行裁定见 [progress.md](progress.md)。

复审未判定的领域逐项处理：Main10 HTTP 与 AVPlayer 实际失败已由上述复验闭环；
最终证据/文档由主执行者核对；基线 decoder 全部正确性未由本次窄复审推出；全格式
release、最低 OS、Intel、其他物理设备、外部声道/音画同步及持续热资格继续开放。

## 保留边界

批准的工程已包含格式路由、受管 progressive、Opus/Vorbis/VP9 严格策略、AV1/VP9
软件候选、共享准入预算、实际解码模式/错误/重建生命周期。生产软件 allowlist 继续
为空：短片和 Debug 采集不能成为持续热或设备资格。AVPlayer source-pull 也不能替代
硬件已播放样本时钟。本轮没有重跑完整 44 格目录、Android 发布或最低系统/Intel，
也没有改动 P08 长播放、弱网 ABR、P05 或主工作区投屏开发。

本地保留最终冻结 App：`packages/yl_player/example/build/p03-acceptance/Runner.app`。
按工具 README 指定显式物理设备即可复跑；仓库仅归档可重放证据和制品清单，不提交 App。
