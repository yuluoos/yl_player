# 定时显示候选完整代码审查

独立只读审查范围：`7d0d4c5..cb4a952`及Task5当时未提交的采集器/测试。使用执行技能要求的一次fresh-context审查；在正式激活矩阵和长播前完成，以便修正后冻结源码身份。无Critical、Minor；四项Important已修正：EOF屏障、horizon回退和paused seek原生RED0/3，paused detach原生RED0/1；修复后相关原生42/42，采集器含异常入口10/10通过。完整集中回归另行执行。

| 发现 | 已复现的失败 | 修正方向 |
| --- | --- | --- |
| 最后一帧离开scheduler后、native enqueue完成前，pending仍false | 原生屏障测试失败；scheduler空且pending=false | 取帧前发布保守的在途状态 |
| 背压帧因rate下降/音频回退而暂时超出新horizon，误当无效帧删除 | 原生回退测试出现pending=false/rejected=1 | 保留一个held帧等待时机；不扩展提前窗口 |
| 退出定时路径后timedSelected不复位，暂停seek无目标画面 | 真实会话paused seek像素为空；paused detach重附着也为空 | 退役后允许暂停预览；仅在暂停detach时保留当前代已到期画面 |
| helper超时等异常绕过owned app清理及run/result落盘 | 调用实际collect入口的subprocess边界测试抛TimeoutExpired | 保存异常与部分输出，结束wrapper，核验/清理已知owned PID，再写失败结果 |

暂停重附着额外保留一个当前画面引用，与最多三个future画面共享既有reservation；不是提前释放系统样本，也没有扩大字节预算。clear/seek不保留旧代画面。系统内部整体资源上界仍未获证明。

审查者未独立重跑音画尾部测试；执行者已取得原生1/1通过，含两种不等长素材各两轮。该结果不能替代EOF竞态屏障测试。正式激活、集中回归、长播当时尚未执行，准入结论以最终验收报告为准。物理输出R4、整体资源边界A5、候选以外的平台/路径继续开放。
