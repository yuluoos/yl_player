# Android Media3 VP9 同次构建身份音画证据

日期：2026-10-16。基线：`08f40e5acc3208a458fe86a73e201d898c84cf21`。
本轮继续获批 P03 Task 7，未改长播放、弱网 ABR 或软件准入档位。

## 通过范围

`native-green-2` 冻结六控制、四阶段，原生测试和独立原始数据门禁均通过 **6/6**。

- run：`f4793af8-aa96-4f7a-8de2-9c602973c5aa`
- APK SHA-256：`8285316d8e8f0762141caf944743d778f574e15198432727e181698be4f0666c`
- 实际 installed APK 在进程内校验，host 文件采集前后不变。
- VP9/Vorbis：产品 `YlMedia3Engine` → Core → 产品 video renderers/codec selector；实际初始化 `c2.goldfish.vp9.decoder` / `c2.android.vorbis.decoder`。
- 其他五项保持 native fallback。每项包含播放四标记、seek 1250/2250/0 ms、完成、dispose 与 AudioTrack 释放。
- 真实 ImageReader 像素配对新读 AudioTrack playback head；PCM 在 Media3 trim 后按原字节透传，固定 48 kHz/stereo/PCM16/1x/无跳静音。每窗口保留 8192 帧 Float32LE，SHA/频率/左右声道由独立 Python 门禁检查。
- VP9 七窗口实际首 PTS：250020、1250000、2250020、3250020、1350020、2350020、100000 us；不搜索偏移或拟合波形。

这是 Android API 36 arm64 TV 模拟器上的 **library instrumentation APK**（产品与 harness 同一容器），不是公开 Flutter release，也不是扬声器/显示器物理同步证明。`fullAcceptance` 固定 false。完整格式矩阵、最低系统/物理设备、iOS 正向硬解、独立参考与持续热准入仍开放。

## 失败历史与回归

- `native-red`：冷启动尚无 package service，安装失败，未播放。
- `native-red-booted`：未连接观察入口，VP9 未产生所需输出且释放卡住，显式结束本任务测试进程；3/6、不完整行、native 不通过，保持失败。
- `native-green-1`：接线后 Media3 实际初始化 VP9/Vorbis，但采集 processor 错误处理空 drain；5/6。底层栈见 `processor-failure.log`。
- `drain-red.log`：先复现空输入不应依赖时间起点/生成样本，再修复。`native-regressions.log`：空 drain + 现有 PCM/格式解码 **23/23**。
- `gate-red.log` → `gate-green.log`：缺实际解码器身份的 Media3 记录不能通过。
- `python-tests.log`：45/45；`catalog.log`：22 fixtures、132 transport rows，仅目录完整性。
- `build-green-1.log`：Android 单元 534 total、531 pass、3 既存 skip，0 failure/error；后续修改仅 androidTest 空 drain guard/注释并重新构建 `build-green-2.log`。
- `negative-identity`：错误预期构建 SHA 在播放前被拒绝；0/6、无可接受记录、nativePassed=false。adb 命令 exit 0 不代表原生测试通过，runner 明确拒绝该结果。
- `final-review.md`：一次全新上下文复审，无 Critical/Important/Minor 发现；独立重放 6/6，并核对错误身份负例。无需修复或复审循环。

## 可重放与边界

运行命令在各目录 `launch.json`，冻结计划在 `plan.json`。`rows.json.gz` 保留原始 PCM 和像素，可直接用 `bound_av.validate(plan, rows)` 复核；runner 另检查 native exit、提取和前后制品一致性。旧 native VP9 不可用结果仍保存在上一轮目录，不被本轮产品 Media3 路线替换。

新增入口均 internal nullable，缺省走原产品 factory/surface；Core 继续安装产品 codec selector，受保护播放拒绝观察 override。采集实现只在 androidTest，不新增公共 API。seek 等真实 sink flush 才采集下一阶段；消费时钟不借用播放器外推位置。超时清理不把未确认释放的输出标为成功。
