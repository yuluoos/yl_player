# P05 JavaScript / RTMP 业务闭环

## 2026-10-11：Task 1 归档离线复核与生成工具

基线 `bdaf7bc`。本批仅交付不依赖设备、原生构建或外部服务的归档复现子项；P05 Task 1 的运行时终止与三端媒体交接复验，以及 Task 2–4 仍未完成。

保存在工作区忽略目录 `.superpowers/sdd/2026-09-22-script-resolver/controlled-samples/` 的九份原始脚本仍可读取，不需要重新下载或改变版本。归档目录 0700，原始文件 0600；按共享 `controlled_contract.dart` 冻结哈希检查，**9/9、共 137,282 字节匹配**。它们已经离开历史 `/private/tmp` 临时目录；这仅证明当前本机工作区可取回，不代表存在异机备份。迁移或删除工作区前仍需另行保留受限归档。原始正文、来源清单和实际地址均不提交。

`generate_controlled_integration.py --verify-only` 新增只读 JSON 校验入口：保留九行分母、预期/实际哈希和字节数；缺失、哈希变化、权限不私有、非普通文件、超限及非法 UTF-8 分别给出固定诊断，不打印任意异常正文或私人路径。缺失整个归档仍输出九行不可用结果，失败返回 1；`executed: false` 明确没有执行脚本。

同一验证路径供实际生成使用。生成器先验证全部字节，使用不跟随符号链接的目录/文件描述符和私有临时文件原子替换，拒绝 tracked/未忽略目标；失败保留旧入口并清理临时文件。`--remove` 同样拒绝输出链接目录。工具面向可信本地 checkout，不宣称能够隔离恶意并发修改仓库的进程。

### 复现与证据

从仓库根目录执行：

```sh
python3 -B -m unittest discover -s packages/yl_player_source_resolver/tool -p 'test_*.py' -v
python3 -B packages/yl_player_source_resolver/tool/generate_controlled_integration.py --archive .superpowers/sdd/2026-09-22-script-resolver/controlled-samples --verify-only
```

自动回归只使用自有合成脚本，真实归档只运行只读校验，不生成含原始字节的 Dart 入口。初始回归在旧实现上复现输出符号链接可写、清理可进入链接目录、重复 manifest ID 未拒绝，以及缺少 verify-only 接口。最终结果与源码哈希见 [verification.json](evidence/2026-10-11-script-archive/verification.json)，安全归档收据见 [archive.json](evidence/2026-10-11-script-archive/archive.json)。

本轮没有重跑历史受控宿主、VM/HTTP 真正释放、iOS/Android/macOS 媒体交接或 TVS 业务用例。九脚本的参数、同步宿主调用、请求要求、未知 expiry 与显式再次解析契约继续沿用[历史逐脚本验收表](2026-09-22-script-resolver.md#冻结脚本验收表)及共享测试；没有从 token 推断期限，也没有把本轮哈希成功计入运行时或线上可用性通过。

### 执行范围决定

沿用现有受限归档，做可重复只读复核及生成器回归；不重复恢复相同字节，也不生成设备入口。理由是归档已在非临时工作区且本轮无需设备；代价是本轮不提供异机备份或新的运行时兼容证据。

独立只读复审结论 Ready，无 Critical/Important/Minor 问题；核对了 17/17 GREEN、源文件哈希、安全收据和范围标注，未读取私有正文。复审未评估的订阅错误/代理路由/业务代际及汇总、VM/HTTP 释放/三端交接、线上服务、异机备份和恶意并发进程隔离均继续保持未验证或明确非承诺范围；分别仍需业务回归、运行时证据、在线抽验、独立备份及可信工作区条件。
