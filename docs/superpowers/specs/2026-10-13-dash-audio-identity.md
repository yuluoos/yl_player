# Apple DASH 多音轨身份与选择

延续 P02 Task1：在现有静态、明文 AVC/AAC DASH 路线上支持每 Period 最多16条
AAC-LC音轨，每个 audio AdaptationSet 保持单Representation（不扩展音频ABR）。
每条音轨生成独立 HLS AUDIO rendition，全部视频变体引用同组，选择一次只播放一条。
音频所有原始轨道仍在质量裁剪前验证，沿用既有受控loader、索引和凭据过滤预算；显式严格managed source准入仍按原策略拒绝，不能把内部loader等同于完整managed能力。

身份由 AdaptationSet id（可缺省）、规范小写语言、排序去重role、codec、采样率和
声道组成并做长度前缀编码后 SHA-256；语言限制128 ASCII字符并检查RFC5646语法（不查注册表）；Representation id、码率、XML顺序、URL及标签
不参与内容身份。缺失语言不猜测；语义重复且无唯一内容标识时拒绝。id是会话内不透明
选择键，不承诺其他引擎相同ID。友好label包含语言/role和必要内容标识用于区分。

各Period必须保有同一完整身份集合；乱序不影响路径，内容标识/语言/role/编码配置
改变、增减或重复音轨，在发布和资源映射前拒绝，不按下标或语言猜测替代。
Ruling：跨Period丢音轨继续明确拒绝整个候选，保留已提交会话；本项不私设音轨回退
策略。代价是仍不支持轨道集合变化的节目，后续需要单独设计跨Period音轨选择失效规则。

HLS NAME使用编译器生成的稳定不透明身份；公共目录投射原始有界语言/label/codec。
AVFoundation选项必须按明确的NAME元数据对应，不能按option数组位置对应。
没有显式DASH音频rendition的媒体保留原有asset内音频路径。普通AVPlayer选项用系统propertyList恢复既有身份，并为新选项分配不复用ID；
属性列表只由系统恢复，不按语言/显示名匹配；无法恢复所选身份时明确报错。不承诺跨Load延续身份。同会话DASH质量重建保留音轨选择，新Load重置。

范围：不改Dart/Pigeon schema；补齐现有 YlMediaTrack 与 selectAudioTrack 注释；
未引入多轨混音、音频ABR、新codec、动态MPD或长播放/弱网工具变更。
验证需包括语义身份乱序/重复/缺失、原始曲目先验证、managed资源映射、DASH
实际公开选轨与失败保持、两端原生回归及Dart合约。真机物理声音与最低系统仍分别记录。

依据：[HLS RFC8216 §4.3.4.1](https://www.rfc-editor.org/rfc/rfc8216.html)、
[AVMediaSelectionOption propertyList](https://developer.apple.com/documentation/avfoundation/avmediaselectionoption/propertylist())。
