# 合并独立复审

Reviewer: /root/remaining_main_merge_review（独立上下文，只读；未运行构建/测试）
Base: 978c2c5c3872d5570e3bd1a01f1a3d2e80d08f44
Head: 11c7f5c357b5b0b46273949f327a4b0f5dae052d

结论：可执行用户已授权、保留已知缺口的合并。Critical 0 / Important 0 / Minor 0。此结论不代表发布就绪。

- Base 是 Head 祖先，0/6，无删除；唯一生产修改为 YlAppleSessionCoordinator.swift 的提前固定流约束校验。
- 校验发生在 willCommit/资源替换前；构造端防御保留，失败候选仍由 open coordinator 取消和释放。
- HLS 回归要求 willCommit=0 和原 AVPlayerItem 身份保持。
- 历史 SHA256SUMS 229 条和内容归档 manifest 219 条核验通过。
- 588 条生产源码清单与发布台账匹配，源码摘要 69f6e5fc191dc55021a1f96b8a2398f8441eee84deeca9ca57521e1819053b60。
- 102 项能力实施/验证/验收状态不变；既有失败、跳过和待验收项完整保留。

边界与处理：
1. 主目录实际运行不由静态复审推断，交由本轮新构建和完整测试记录。
2. P04 自动恢复、P08 A5/119ms、P07 全映射/独立参考/DV、外部矩阵继续开放，不重新判成通过。
3. 脱敏前原始日志内容无法由审查者独立重放；归档内容和哈希内部一致，保留来源与脱敏边界。

## 主目录全套后的定向修复复核

macOS 全套实际859通过/1失败。失败 `YlMacosAudioTests/testActualDecodedLegacyEOFSuspendResumeDoesNotAutoplay()` 在内部已completed但异步公开回调尚未交付时断言0==1；后续同次运行完成次数为1。测试等待条件此前只观察内部状态。

修复规范测试及适配后的主例副本：在原10秒窗口内同时等内部及公开completed；未改生产、完成次数、资源、迟到回调隔离、suspend/resume不自动播放等断言。

同一reviewer定向复核发现Important1/P2：helper的重播EOF等待仍存在同类竞态。核对后补上原10秒内completions()>=2的等待，随后精确==2不变。复核确认关闭，最终Critical0/Important0/Minor0。reviewer未代替主代理运行测试；运行结果见本轮三个recheck收据。
