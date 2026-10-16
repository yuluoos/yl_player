# Dolby 映射与证据契约（P07 Task1 调查阶段）

2026-09-28，基线 `e69d5dc`。本契约冻结调查与比较规则，尚未冻结完整映射支持集合或最终画质容差。遵循 REQ-01/12/15：系统及开源，不接商业SDK；保留现有FEL，不以BL、去掉trims或更换Profile代替完整结果。Android24、iOS15、macOS12部署下限不变。

## 三种证据分别成立

| 证据 | 必须观察 | 当前 |
|---|---|---|
| 算术重建 | 已固定输入/系数、独立计算、明确数值域与取样位置 | macOS现有合成小图选定像素通过；不能泛化真实Profile |
| 目标显示映射画质 | 原始有效流+未篡改动态元数据、独立目标输出、目标显示参数、帧/空间对齐及事先固定容差 | 缺参考与容差，external_missing |
| 原生DV信号 | 设备/系统/连接/转接器/显示器固件与模式、实际信号证据、动态切换恢复 | 链路未指定，external_missing；DV标签不替代画质 |

`cases.json` schema1只记录待验证组合，不能存放通过结论。六类为5、7-MEL、7-FEL、8.1、8.2、8.4；CM2.9/4.0和L1/L2/L4/L5/L6/L8是调查维度，不能从Profile推断CM或levels。24行是首轮覆盖网格，不是规范全集；未知合法level必须扩大调查并明确不支持，不能忽略或标损坏。

## 既有算术边界

现有测试输入是Swift合成10-bit BL/EL与系数字典，没有原始媒体文件。Metal输出为线性BT.2020 RGBAHalf，1.0对应100nit；GPU输出转为Double与独立scalar公式对照。现有断言为 `abs(actual-expected) < max(0.003, abs(expected)*0.003)`，仅覆盖指定像素/通道、残差正负/零、MMR、半尺寸EL横向插值等。

这条算术容差不移植为屏幕映射容差，不证明完整图像、色度边缘或物理亮度。原始RPU附加值只表来源，不能证明系统在重建RGB上执行了Dolby显示管理。当前metadata只接收L1/L5/L6（不等于已执行全部语义），拒绝creative trims、非单位NLQ最大值及其他不支持的信号/重采样配置；Task2方可修改这些行为。

## 取得参考后的比较门槛

在修改映射前，为每一支持行记录：原始媒体与RPU哈希、使用依据、实际Profile/CM/每帧levels，独立参考生成者和版本/配置、参考输出哈希、显示峰值/黑位/白点/色域/EOTF/环境光条件。独立参考不能由被测compositor产生，也不能仅改用共享同一算法的候选输出。

冻结帧序号与有理数PTS对应、分辨率/像素宽高比/色度位置/active area。重建算术在明确的信号域比较；最终显示映射优先保留线性绝对亮度RGB与原始码值，比较前使用另行验证的同域转换。记录最大绝对误差、RMSE、分位误差与误差位置；感知色差仅在变换及参考白点有依据时补充。不得归一化实际结果去迎合参考。

全帧、有效画面、裁剪边界和色度边缘分别统计；L5控制的黑边不能简单删掉。至少覆盖动态元数据改变前/后、镜头切换、峰值/黑位变化。阈值、裁剪区域和失败标准须在查看被测结果前按参考精度/量化/目标需求冻结。**目前这些数值阈值及最终目标参数为空，禁止据此宣布画质通过或开始未证实映射实现。**

## 后续实验次序

1. 恢复可用原始FEL并核验授权/哈希，保留非单位NLQ与L2/L4原值；与单层官方样本分别盘点，禁止用修剪元数据衍生物顶替。
2. 核查并构建固定候选的实际平台后端，证明双层不丢失、浮点/10-bit导入导出及帧同步，再决定是否接入；库能编译不等于画质通过。
3. 取得独立多帧目标输出，确定NLQ非单位范围、重采样边界、L2/L8/CM具体差距与容差；按证实子集推进Task2/3。
4. 另行核验物理DV链路及性能。PD-02尚未确认时不新增自动HDR/SDR/DV转换策略。


## 全片输入盘点边界（2026-10-16）

`stream_inventory.py` 提供Task1输入依赖，读取单HEVC轨道MP4的原始NAL和容器PTS/DTS，固定libdovi解析全部选中数据包的RPU。数据包不等于已验证解码帧；容器PTS排序不等于物理显示时序。复用mapping、未解析剩余位和未知level必须保留计数，不从出现字段推导处理支持。元数据变化使用完整signalled display metadata规范JSON哈希，不能当成镜头切换、亮度误差或已执行trim的证明。

盘点轨迹只能提供原始RPU字节hash、整数时间戳和元数据hash/level/profile信息，不填独立目标参考hash或最终容差。原调查schema1仍禁止状态提升。实际源文件和解析器hash在盘点前后校验，部分失败和资源超限拒绝整体成功；退出2不等于媒体损坏。取得参考后仍须另行验证有效元数据继承、解码帧对应和同域像素比较。

## 2026-10-16：现有 schema v1 的准入与错误边界

本节固定现有桥接校验，不扩展像素算法或完整 CM 支持。字段来源为生产 `YlFELBridge.inc` 及已固定 FFmpeg9.0.1 的 `dovi_meta.h` / `dovi_rpudec.c`：L1 三项 PQ 是12-bit整数，L5四边偏移是13-bit整数像素，L6四项静态字段是16-bit整数。L6原始字段保留各自单位，不把最小亮度整数与最大亮度整数直接比较。最多32个扩展块；L1/L5/L6各自最多一次。

- 整数先按原始 NSNumber 检查类型和整数性，再转 Float；布尔值不能充当整数/系数。系数必须能以有限Float表示。用于语法/能力判断的NLQ最大值按Double检查，不能四舍五入为1后误当已支持。
- schema v1中缺字段、非有限系数、整数/位宽越界、重复单例块、非法pivot/MMR、负NLQ offset/slope/maximum及空L5有效区域是损坏；`decoder.dolby_vision_fel_invalid` / decoder / 不可重试。
- 未知schema、有合法语法但当前未实现的信号/重采样、非单位NLQ最大值、L2/L4/L8等creative blocks、L254 CM信息或其他未知level保持unsupported；`decoder.dolby_vision_fel_metadata_unsupported` / unsupported / 不可重试。未知schema不按v1推断其剩余布局。
- 已知块和数值先验证，再判断当前能力；未知块只保留其存在并拒绝处理，不宣称验证了未知块内部语义。桥接层本身已经返回的`YLFResultDolbyVisionUnsupported`不得在Swift配置/逐包入口折叠成损坏。
- L5四边偏移必须留下正面积：left+right < decodedWidth，top+bottom < decodedHeight。配置探测和逐包入口都验证。这里不新增裁剪或显示映射，不把验证通过当作已应用L5显示管理。
- 错误经既有安全发布边界生成scope和diagnosticId；不把输入字典、原生诊断或地址带到公开message。探测预算超限保留resource分类，不报成解码损坏。

Shader ABI仍为709个Float：residual[0]、counts[1..3]、pivots[4..30]、methods[31..54]、polynomial[55..126]、MMR order[127..150]、constant[151..174]、coefficients[175..678]、nonlinear offset[679..681]、YCC matrix[682..690]、LMS matrix[691..699]、NLQ offset[700..702]、slope[703..705]、threshold[706..708]。显示块不混入该数组；Float布局不改变既有Metal运算。

这些检查不构成完整RPU规范验证，不改变FFmpeg解析器对未知RPU类型的既有判断，也不解决有效元数据继承、trim、独立目标图比较或原生DV输出。
