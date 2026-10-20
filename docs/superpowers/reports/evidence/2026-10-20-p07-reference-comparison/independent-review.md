# 独立综合复审与修复收据

审查者：fresh-context `/root/p07_comparison_review`，gpt-6-astra / high；基线175145fc后的本次完整工作树改动，包含新文件。按用户集中验收要求，一次综合复审，复用完整验证证据，没有重复原生矩阵。

## 审查返回

结论：1 Important/P2、1 Minor、0 Critical。未发现数值比较误放行或 CAP 自动提升。

- Important/P2：`pixel_compare.py` 原141/181/235行的 `Path.resolve(strict=True)` 在 Python3.12 遇循环符号链接抛 RuntimeError，未被CLI捕获。审查者定向复现 actual symlink 循环：退出1、stdout空、stderr有traceback/路径，违背非法输入退出2与安全错误契约。建议在路径解析边界转ComparisonError，并覆盖asset与contract/capture路径。
- Minor：报告所称EXR960 HTTP206请求收据没有进入range-observations.json，只有解析值。建议补收据或收窄表述。

范围：两份实现、两份测试、合成夹具、依赖、契约、计划和报告；整数/有理数定位、帧匹配、几何与读取限制、hash/target/generation、全图/ROI指标、候选退出码及CAP字段。复用Python/Rust/HDR/Metal日志，核对4K结果；独立核验合成fixture合同及像素hash，只额外执行symlink反例。

未判定：独立目标生成、跨序列帧对应、FEL同源参考、完整CM/trim/NLQ、真实物理DV。报告保留这些限制是正确的。最终SHA256SUMS及收尾归档由实现者负责。

## 实现者处理与修复后的定向复核

接受P2。新增真实CLI用例覆盖contract、capture、reference、actual、evidence五个循环链接位置；修复前14项中此新增测试出现5个失败子例（review-fix-red.txt）。新增统一resolve_path，仅在路径解析边界把RuntimeError转为ComparisonError；OSError继续走已有安全错误处理。修复后比较器全部14项通过（review-fix-green.txt），五个位置均退出2、输出固定错误JSON、stderr为空。

补齐证据：单独重取第960帧bytes0–4095，HTTP206、Content-Range为bytes0–4095/53119100。新头与此前缓存逐字节一致，SHA256 fa031d3794fd440e9a0301b53eccd93dd818685cbdd8a0e4a0bca3292c160ab0；URL/ETag/解析值和复取说明已进入range-observations.json。不是第二次综合代码复审。

路径异常修复只涉及比较器的路径解析及新回归测试，数值算法、其他Python/原生/Rust源码、依赖和运行环境均未改变。依集中验收规则保留此前67项矩阵（66通过/1原有CGL跳过）及Rust/HDR/Metal/P5/P7证据，修复后仅重跑受影响的比较器全部14项，不把两轮计数相加宣称一次全套结果。源码最终字节由SHA256SUMS绑定。

无未处理Critical/Important；证据Minor也已补齐。当前工程增量可提交；完整P07/CAP-DV-MAP/OUT仍未验收。未判定项继续作为外部参考、算法及物理验收边界，不用合成测试替代。
