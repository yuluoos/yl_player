# macOS 同构建格式矩阵通过

MacBookPro17,1（M1、macOS 27.0.1 / 26A434）在同一个已签名 example 应用中完成 22 份固定素材的本地文件和受管 HTTP 测试。44 个场景全部执行，40 个必测场景全部通过。矩阵 ID 为 `fc94900d-23d4-433d-860e-9359c81c037f`，应用逐文件清单 SHA-256 为 `0d16457b02dc4cb6e53b8e7ed4aea06cd34136be3e3cbe82430e0495e0db8dbf`。归档原始记录的离线重放与现场逐项结果一致。[逐格结果](evidence/2026-11-03-macos-qualified-format-matrix/final-matrix/matrix-result.json) · [原始记录](evidence/2026-11-03-macos-qualified-format-matrix/final-matrix/records.json.xz)

| 场景 | 数量 | 实际结果 |
| --- | ---: | --- |
| 正常文件和受管 HTTP | 40 | 40 项均取得同会话画面、音频、三次 seek、完成及释放证据 |
| MPEG-2 PS 诊断 | 2 | 两种传输均报告 `decoder.unsupported` |
| 截断 MP4 | 2 | 文件报告 `avplayer.-11829`，HTTP 报告 `container.mp4_open_failed` |

观测 SDK 使用 arm64 Release 优化，编入显式 Debug 观测钩子。两轮独立资格长播各连续 1204.53 秒，均完整解码 28,904 帧，系统层计数为预览 1 帧加定时层 28,903 帧，应用和系统零丢帧，零损坏、零时钟过期。CPU 峰值分别为 218.870 和 236.956ms/秒，冻结 CPU 预算为 274ms/秒。原生调用峰值分别为 4.527 和 3.242ms，固定上限为 42ms。观测 Swift 映像为 `63049f3633429d8a688060c1c06564fb13847551381d706b6bda2032b559f392`，codec 为 `4a2083b42c52de082d170f1aced30c6fff67b8e93e40961068b2b2ac0e62dd5d`。这份准入档位绑定此次观测映像。[协议](evidence/2026-11-03-macos-qualified-format-matrix/qualification/protocol.json) · [签发档位](evidence/2026-11-03-macos-qualified-format-matrix/qualification/yl-player-qualified-av1.json)

矩阵的 Xcode 原生宿主使用 Debug 配置，Flutter 测试前端以 Profile AOT 运行，通过正常插件注册加载已签发的 SDK。最初预检发现启动器优先加载 DerivedData 中的 codec，运行时身份校验拒绝了这次采集。封装工具移除了启动器和包包装库中指向 PackageFrameworks 的绝对搜索路径。最终 40 个必测场景的加载记录都与签发档位的两项哈希相符，44 个子进程均记录了实际 Dart 模式。[封装步骤](../../../tool/media_matrix/BOUND_AV.md#complete-catalog-through-the-public-flutter-path) · [运行模式和重放回执](evidence/2026-11-03-macos-qualified-format-matrix/final-matrix/runtime-and-replay.json)

首轮 JIT 矩阵为 38/40。文件与 HTTP AV1 均已准入并返回暂停画面，随后出现 `resource.exhausted`。相同 SDK 和档位的测量宿主复现 CPU 峰值 284.057ms/秒，单次调用仅 0.701ms。采样窗口中存在 Dart JIT 编译、GC 和 Flutter 平台视图合成。精简 Material 控件树仍失败。切换 AOT 后 JIT 样本消失，仍测到 275.728ms/秒，单独将读回间隔放宽到 350ms 的对照也超限。两项对照均已保留。[首轮矩阵](evidence/2026-11-03-macos-qualified-format-matrix/jit-matrix/matrix-result.json) · [诊断记录](evidence/2026-11-03-macos-qualified-format-matrix/diagnostics/)

AOT 栈记录了测试绑定驱动的绘制及原生视图重复合成。Flutter 的 fullyLive 测试绑定在每次绘制结束后请求下一次 vsync。macOS 矩阵现在按框架的真实布局、绘制和尺寸变更请求提交帧。恢复原 150ms 采样间隔后，AV1 文件对照取得全部画面与 PCM 配对，CPU 峰值为 243.336ms/秒。最终矩阵保留完整 Material 控件树和原始双样本判定，使用正常注册重新执行全部 44 格。两种传输的 AV1 均通过播放及 1250、2250、0ms 三次 seek 的七组配对。[按需绘制对照](evidence/2026-11-03-macos-qualified-format-matrix/diagnostics/on-demand-cell-result.json)

本地 MP4 的七组标记均通过声学核验。内置麦克风助手记录固定音频带能量和时间戳。该格结束后扬声器从 55% 恢复至原来的音量 0 和静音。[声学结果](evidence/2026-11-03-macos-qualified-format-matrix/final-matrix/local-mp4-result.json) · [恢复记录](evidence/2026-11-03-macos-qualified-format-matrix/final-volume-restoration.json)

固定矩阵的 `formatScopeAcceptance=true`。CAP-FORMAT 组级验收仍需其他目标设备、最低系统及独立参考与输出边界证据。正式应用位于工作区 `build/macos-format-matrix-20261103/final-aot-matrix.app`。[证据哈希清单](evidence/2026-11-03-macos-qualified-format-matrix/sha256.json)
