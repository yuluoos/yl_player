# 一次独立整批复审

复审范围：player 工作树全部 tracked/untracked 改动（base 86143754），以及 TVS codex/p08-measurements 改动。独立 fresh-context reviewer，未让其修改代码，没有第二轮复审。

- Important：DRM 在 trace 关闭前打印 incomplete。独立复现 scope 内 false、关闭后 true。增加关闭回调并在 sealed 状态输出，异常路径同样输出；新增 pending+throw 回归。
- Important：TVS collector 在最终宿主二进制缺失时仍返回 success。真实缺失文件场景 RED（returned true），改为全部取证成功后才赋 complete；GREEN3/3。
- 原 Minor，按失败隔离影响重定级并修复：opening 采样异常可能留下 periodic timer。获得 timer 时立即登记取消，opening 也纳入 finally，disposed 采样失败仍 close；新增 opening 失败后不再采样回归。
- 原 Minor，按用户“能完成的都做完”在同一修正批次处理：TVS scriptResolution 起点改为包含 parse/resolve 启动，而不是仅等待 result。完整 live + session 测试362/362，分析和 build_runner 通过。

DRM/sampler 新测试首次因缺少新增安全接口而失败；实现后相关14/14通过。修正后的整体基础/P08门禁及实际压力复测另见 validation.json。无延期 Minor。

不裁定为通过：物理 scanout、A/V/字幕同步、最低系统、Intel runtime、Android 低内存/32-bit、授权 DRM、iPhone 运行。这些需设备或可信输出条件。当前机器的 compositor 和公开事件边界不混写。
