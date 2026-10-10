# R5复审修正及最终本机验证（2026-10-09）

## 已保留的修复前证据

base3364768的完整上下文诊断在180s默认/最大单项预算、1200s父预算下通过672/672，456源码和5二进制哈希保持不变。独立复审提出唯一P2：同renderer/generation的首次PCM提交锚点在main队列迟于pause送达，会覆盖冻结位置；resume以当前sample重新计时，丢失此前已经消费的区间。此问题不由完整套件通过自动排除。旧5帧丢弃失败仍保留，诊断未复现不构成根因修复。

## 唯一复审修复轮

先添加通过实际pipeline回调、presentation coordinator和真实media clock的确定性交错：first submission事件入main队列→pause冻结→事件送达→resume；同时覆盖0/非零PTS、初始play前锚定、seek后的新generation锚定和旧generation隔离。先确认RED，再仅修正候选首次提交锚点的暂停语义。普通同步锚点语义不变；暂停位置保持，resume仍基于当时实际renderer sample重新计时，seek允许新映射。

## 最终验证顺序和门禁

1. 目标回归及邻接clock/pipeline/session测试；保留RED和GREEN。
2. 因修改共享生产时钟路径，旧iOS结果仅属历史证据，重新在用户偏好的iPhone18 Pro Max模拟器执行完整套件；硬件条件跳过仍须逐身份解释。
3. 同最终源码执行完整macOS套件，default/max180s、串行、父1200s；不启用诊断/heap/MSL。冻结相关源码、测试/fixture/bridge/配置和实际二进制，核对完整规范身份。
4. 完整门禁通过才执行一次原采集器无探针30s short，再在相同身份执行一次>=1200s long。保持原原生90/1380s、父180/1500s和全部进度、零活动丢帧、顺序、时钟、释放门限，不增加缓存或放宽门限。不与其他原生运行、构建、heap并行。
5. 任一步新失败保留并依据证据处理，不循环重跑求通过。最终归档保存可离线复核的原始结果、身份和重算结果。

资源A5不准入、最低OS/Intel/真实音频路由/物理音画等外部缺口继续有效。defaultEnabled、productionAdmission、downstreamBoundProven继续为false；本机通过不代表候选上线或全进程内存有界。不引入商业SDK，不提高最低版本，不push。
