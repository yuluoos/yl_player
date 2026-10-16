# 用户补充样本线索，2026-10-16

入口：[Fivk测试视频合集](https://blog.fivk.cn/archives/6647.html)。本次读取文章、Dolby官方说明及dovi_tool维护者讨论；尚未下载/核验文章两个夸克分享中的实际媒体，未形成输入哈希或参考哈希。

| 线索 | 可用于什么 | 本次不能确认什么 |
|---|---|---|
| FEL_test_for_AVS（ISO/M2TS/MKV/MP4） | 候选FEL参与处理/不同封装的功能性测试 | 分享文件是否与原始发布一致、BL/EL/RPU组合、生成说明、最终画质参考 |
| CM4_L3L8_Test_with_CM29_fallback（P5/P8.1） | 按文章描述，可补CM4/L3/L8及CM2.9回退响应观察 | 文件实际元数据、作者/生成过程、目标显示参数、数值golden |
| Dolby Browser Test Kit | 官方说明确认P5/P8.1/P8.4及MP4/HLS/DASH测试内容 | 不含P7 FEL覆盖声明；不因此取得完整映射的独立逐帧参考 |

[Dolby官方测试内容说明](https://ott.dolby.com/browser_test_kit/help_files/topics/r_test_signals_all.html)提供官方MP4归档入口和Profile范围。[官方指南](https://ott.dolby.com/browser_test_kit/help_files/topics/r_testing_guide.html)说明测试设备/浏览器条件。官方材料有测试用途，不将其页面版权声明解释为允许再分发媒体；本次不提交媒体。

[dovi_tool维护者讨论168](https://github.com/quietvoid/dovi_tool/discussions/168)针对所讨论的AVS测试图指出使用随机RPU，并说明不能盲目remove_mapping或忽略原有mapping。本次无法核验网盘文件与该讨论版本相同，因此这是追溯时必须检查的问题，不将全部同名文件直接判无效。

结论：线索有用，可以补输入与功能性反例；“看到80秒的人物/明暗变化”不能单独证明完整CM映射精度。P07仍需要同一原始输入、明确目标显示参数和独立生成的参考帧/数值及预先冻结容差。用户确认暂时没有该独立参考。网页读取工具无法访问两个夸克分享，AVS原帖本次读取也失败；没有绕过登录或改写位流。
