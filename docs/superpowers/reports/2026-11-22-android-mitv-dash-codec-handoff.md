# 小米电视 DASH 单解码器 AVC → HEVC 验收

小米 MiTV-MTTP0（Android 9 / API 28，32 位）在同一测试 APK 上独立完成两批，每批使用原来的五组素材、每组三轮。30/30 轮通过 Android 冻结门槛，共 3,051 帧有对应的 AudioTrack 时钟。六次跨编码切换都观察到 1,458,333 µs 的最后一帧 AVC 和 1,500,000 µs 的第一帧 HEVC。[冻结门槛](../../../tool/dash_timeline/joint_acceptance.json) · [修复前同机数据](2026-11-22-android-mitv-dash-first-frame-and-hevc.md)

| 批次 | 全矩阵配对帧 | 全矩阵最大绝对音画偏差（ms） | HEVC 首帧最大绝对偏差（ms） | 跨编码输出间隔最大超额（ms） | 按下游 GPU 通知计算的边界最大绝对偏差（ms） |
| --- | ---: | ---: | ---: | ---: | ---: |
| 首批 | 1,524 | 38.084 | 20.449 | 25.000 | 13.198 |
| 同包复跑 | 1,527 | 46.870 | 17.435 | 36.129 | 35.684 |

修复前六轮的 HEVC 首帧最大绝对偏差为 256.494 ms，输出间隔最大超额为 271.150 ms。冻结判定读取真实输出像素、视频 PTS 和消费时钟，将音频位置换算到输出纹理时间戳，限值分别为 70 ms 和 100 ms。Media3 合成输出保留节目时间戳，源 Representation ID 在图输出端为空。采集器通过两段素材互不重叠的实际颜色识别 Period，逐帧核对颜色，并检查两侧边界帧均在场。

## 播放器改动

对这台受限电视上符合条件的连续两段非加密 SD 节目，Media3 的帧缓存容量设为八张，播放线程继续按时送出 AVC 尾帧。后台线程先释放 MStar AVC 实例，再准备 HEVC 实例。两代解码器的所有权在同一个串行队列中交接。跳转、换面、停用或释放时会清理尚未接管的解码器。Media3 的 HEVC 初始化事件在接管时计时，后台准备耗时另计。

自动起播时，从首张合成画面备好开始等待 AudioTrack 前进。渲染器从原生 SurfaceHolder 或 Flutter 纹理所有者取得实际缓冲尺寸，在输出尺寸改变时更新视口。普通单编码素材沿用原有输出路径。

## 回归与观察范围

- 公开 Flutter 播放器在同机完成 19/19 项跨段回归，包含跨编码、暂停后跳转、几何变化和播放完成。
- 在 AVC 段中途暂停，播放线程确认暂停后保留一帧传递余量，650 ms 暂停窗口内新增画面为 0，恢复后播放至结尾。
- 使用 1920×1080 输出纹理，在宽高的 10%、50%、90% 交点回读像素。共 68 帧通过九点颜色检查，覆盖中心、四边和四角。
- Android JVM 共 643 项，640 项通过，3 项跳过。DASH 宿主测试 20/20 通过。

此前一次候选包复跑中，直接输出的 `clip-end` 第 2 帧曾出现 90.373 ms 偏差，首帧和第 2 帧的释放相隔 123 ms。最终同包两批均通过此素材。另按 GPU 回调开始时间换算，两批跨编码素材中最慢的一次整段起播首帧为 78.691 ms。该时刻还包含纹理通知调度。屏幕扫描与扬声器物理延迟未测量。

Android 公开测试持续刷新画面。首次复跑时，选轨命令已返回，状态流仍短暂显示自动选择。最终回归等待状态流确认此次指定的 HEVC 轨道和用户选择原因。sim-use 界面桥未响应，电视系统合成画面通过 ADB 抓取。AVC 和 HEVC 的四张标记画面均覆盖全屏像素的 99.804%，每张的九个采样点都匹配。[AVC 画面 1920×1080](evidence/2026-11-22-android-mitv-dash-codec-handoff/avc-red.png) · [HEVC 画面 1920×1080](evidence/2026-11-22-android-mitv-dash-codec-handoff/hevc-yellow.png)

## 复算

原生测试 APK 的 SHA-256 为 `ad373ef6e0214b29cf34abe43f9aa8c1fe4a741a79bc2ba0eef8e016ebe54bd7`。两批均核对了电视已安装 APK 的哈希。[逐轮数据及源码哈希](evidence/2026-11-22-android-mitv-dash-codec-handoff/results.json) · [采样、回执与候选对照](evidence/2026-11-22-android-mitv-dash-codec-handoff/captures.tar.xz)

解压后，从仓库根目录对两个批次分别运行同一判定。

```sh
python3 -B tool/dash_timeline/joint_observations.py verified/final/samples.log --platform android --limits tool/dash_timeline/joint_acceptance.json --output first.json
python3 -B tool/dash_timeline/joint_observations.py verified/repeat/samples.log --platform android --limits tool/dash_timeline/joint_acceptance.json --output repeat.json
```
