# Apple DASH Period-aware video catalog

基线 `2aa997c` 已提交加载时严格上限。用户要求 commit 后进入下一阶段；本阶段在现有已授权 DASH/清晰度工作内，交付真实的当前 Period 档位目录，作为固定档位与 PD-01 的前置基础。无商业 SDK，沿用当前工作区和原生公开接口，不新增外部服务依赖。

## 目标与取舍

现有 AVPlayer 元数据把 AVAsset 的视频轨道当成 DASH Representation 目录，且把每条轨道标成 selected，不能支持可靠的档位显示或后续固定选择。采用已验证 MPD 的不可变时间轴/目录，经编译结果、loader 和已安装 backend 传递；只有成功提交的候选可更新公开目录。相比从 AVAsset 或请求路径推断，直接保存解析时已验证信息不受预取与异步元数据影响。

本阶段公开的 `state.videoTracks` 是当前播放 Period 中、已接受 Load 上限过滤后的可用声明档位；不代表实际解码器正在选择哪一档。DASH 所有 `isSelected` 均为 false，`videoSelection` 保持 automatic/initial。固定选择继续明确 unsupported，运行中变更 DASH 上限继续 reload-required。运行时事务、固定/PD-01 自动回退、弱网 ABR 均仍是已接受后续工作，不以此目录阶段宣称完成。

## 数据与身份

保留解析器已经验证的每段精确 startUs/endUs（Int64 微秒），过滤 Representation 时保留这些边界。内部不可变 `YlDashVideoCatalog` 保存 Period 时间区间与有效视频质量条目，并由 `YlDashHlsPresentation` 持有。目录来自已接受过滤后 Period；不重复解析、不保留整棵 XML，也不把音频带宽计入视频 bitrate。

档位 ID 为 `dash-video-w{width}-h{height}-b{bandwidth}`，只含固定前缀和已验证数值，与 Representation ID、XML 顺序、Period 序号、URL 和凭据无关。同一质量在节目内增删再出现使用同 ID。宽高/bitrate/codec 来自 MPD 声明，codec 保留声明值；不把声明升级为解码或 HDR 保证。每 Period 按 width/height/bitrate 升序输出，完全相同质量元组只输出一次，不因此新增清单拒绝条件；不改变已接受的 unconstrained legacy 域或既有 caps 严格族检查。原64 Period/256 Representation 等全部预算保持，目录空间受其限制。

内部查询 `tracks(at positionUs: Int64)` 使用左闭右开区间；正好位于边界属于下一 Period，负值钳制为0，完成点及超过末尾保留最后 Period。内部微秒精度不得先截断成毫秒再查询。无可用播放时间时初始选第一 Period，失活时使用已保存位置；时间转换必须有限、溢出安全。公开 schema 不新增 period 字段。

## 发布与生命周期

loader 提供锁内取得的不可变目录快照；取消清除 loader 的私有目录。backend 在已安装 DASH item 拿到目录，普通 HLS/MP4 没有 DASH 目录。自然进度和真实 seek 落点使目录跟随实际 program time；不能在 seek 命令发出但尚未生效时乐观更新，也不能因预取后段媒体而提前切换。发布轨道变化和相应完整状态，使同一状态的 position 与档位匹配；相同档位目录不在每个 tick 重复触发 tracksChanged。元数据回调可以继续更新几何/音频，但不能覆盖 DASH 目录或将其标为 selected。

保持旧会话直到新 Load 成功提交；失败/取消候选不能发布其目录。失活/恢复使用正确已接受目录与实际/保存位置；Stop、dispose、切换普通源清除旧 DASH 状态；退休 item 的元数据/周期回调不能将旧目录写入新会话。普通 HLS/MP4 的现有 AVAsset 轨道行为保持；上阶段实际尺寸保护、凭据/预算、失败回滚和 HLS 偏好恢复不被改写。

## 验收

原生两平台定向测试：解析出的微秒边界含非整数毫秒；稳定身份和排序；重排/增删/再出现；cap 投影；边界前/正好边界/完成/负值/过大值；legacy varying bitrate 接受域；目录无地址或原始表示ID；loader快照取消；backend自然/seek/暂停/保存位置/恢复；无每tick重复轨道事件；新旧候选/Stop/普通源及迟到元数据隔离。对生产状态发布路径测行为，不能只有不接线的纯 helper。新测试同步 canonical + iOS/macOS 镜像及 current inventory，历史清单不变。代表性回归先观察行为 RED，再 GREEN。

公开 Flutter 单文件三例在 macOS 与 iOS Simulator 串行：
1. 两段多档位 manifest：首帧后目录两档、自动/initial、全部isSelected=false，自然跨段与seek后同一质量ID保持，尺寸/视频码率正确，最终完成。
2. high→low：首段仅640×360/700000；实际跨段后仅320×180/350000；seek回1秒恢复高档同ID，seek到5秒恢复低档同ID；检查真实播放位置和几何，不用预取决定Period。
3. cap320×180/350000：两段仅低档目录；不满足180上限的高→低候选Load失败、零候选媒体请求，旧目录/身份/进度保持；Stop后目录为空。显式DASH和automatic.mpd都覆盖。

只运行相关 native + 这三例公开测试/定向Dart分析；不重复Android或无关全套。记录分批覆盖、日志/警告/真实设备信息；恢复自有模拟器和四处Flutter target。任务复审和一次整阶段复审，修复集中处理。新阶段不自动提交或推送，供下次commit。
