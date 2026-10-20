# 本轮验证证据

最终实现提交 `c2a16196891f`，基线 `978c2c5c`，分支 `codex/remaining-engineering`。本轮实现、失败修复和集中验证结束，整体工程验收/发布仍未通过。

- `validation.json`：实际汇总与限制；macOS当前860个规范身份都有通过证据，iOS当前779通过/33失败/1有附件的跳过。这是一次全套加受影响回归的合并覆盖，不能称为一次最终全套全绿。
- `captures.tar.gz` / `capture-manifest.json`：timed短诊断、两次早期ABR对照、正式ABR、完整FEL/P5解码和映射轨迹、定向RED/GREEN。原始字节与脱敏字节各自绑定哈希。
- `cross-check.json`：逐包实际解码与mapping的PTS/DTS/RPU/元数据及探针源码身份。
- `foundation-summary.json` / `foundation.txt.gz` / `dolby-final.txt.gz`：完整基础矩阵以及复审修复后显式开启真实探针的Dolby全套。
- `native/coverage/`：各轮真实XCTest身份、摘要与累计覆盖依据；所有初始/中间失败保留。`native/ios-failures/`保留初始40项失败的位置；最终33项名单在validation与coverage中。
- `native/ios-identities/` / `native/ios-session-identities/` / `native/ios-flv-capability/`：原始与最终R19跳过及真实H264不可用附件。`native/macos-resource-attachments/`保留最终真实EOF/生命周期资源附件。
- `native/`：构建/执行/RED日志、初始控制台、定向失败活动、命令与退出状态。错误SDK清单/早期编译修正等设置错误也保留，不能充当行为RED。某次小型runner结果文件被后续运行复用，原始elapsed秒数缺失已在重建收据说明；原日志、xcresult摘要和失败内容仍保留。
- `readiness-before-hls-fix/`与`readiness/`：修复前后台账有效性/阈值检查通过、require-ready失败。`source-reconciliation.json`记录唯一生产差异；未提升能力状态，也未添加验收通过证明。
- `independent-review.md`：一轮综合复审与同一reviewer的定向修复核对；Important1已修复，无deferred minor。最后本地媒体夹具修正经过自查与8/8运行验证。
- `execution-ledger.md`：执行过程中保留的裁决、检查点和未完成项。`main-preservation.json`：主目录保护检查。
- `verification-manifest.json`绑定每份验证日志的原始/脱敏内容/压缩哈希；`SHA256SUMS`绑定当前全部版本化证据文件。

日志只脱敏本地路径、UUID和运行握手token，保留实际数值、断言、失败/跳过及SDK警告。验证附件采用稳定匿名UUID映射，避免多附件合并碰撞。压缩JSON/text需解压读取；未提交媒体、可执行探针、framework或完整xcresult二进制包。素材身份见主报告，原始缓存仍位于主目录已有研究目录。可执行文件哈希不冻结所有动态库或整台机器。

P08历史119ms根因/A5上界、P04自动恢复升档、P07完整有效映射/独立目标/物理DV及其他外部矩阵仍开放。诊断成功不等于生产准入。最终生产仅增加固定流约束的切换前校验；较早timed/ABR捕获保持原源码身份，不改标成最终修订的性能证明。
