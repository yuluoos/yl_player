# iOS 提交后媒体失败与 Dart 凭据生命周期

基线 `90be00d1`，分支 `codex/abr-recovery`。继续已授权剩余项，沿用系统排障与集中验收，不发布。[原始证据](evidence/2026-10-28-ios-postcommit-failure/)保留失败、最终源码与完整原生结果。

## 已补齐的边界

成功 Load 回复表示新会话已经安装，不表示媒体已 ready。新增原生合约通过有效 MPD、真实 AVPlayer 与跨源302后HTTP410，验证已提交会话随后进入 item.failed，并向相同session发送失败事件；保持该会话身份，不错误要求自动回滚旧会话。

调用原生host.suspend/resume后，重建loader仍沿用同一个凭据剥离上下文；唯一Range探测确认恢复后不再发送Authorization、Cookie、显式X-Session，普通header保留。再次公开Load使用独立上下文和新的合成凭据，旧loader取消，旧session命令被拒绝。新loader的另一次唯一Range完整探测返回410，逐Load检查跨源hop与返回终点，旧上下文版本不变。这是原生生命周期方法调用，未声称发生过真实系统后台/前台切换。

新增真实Flutter集成测试，经过Dart控制器、Pigeon通道和原生播放器：两个顺序Load分别提交、ready和firstFrame future均以YlPlayerException失败、状态为failed且失败事件各归对应session，新Load使用自己的凭据，旧session命令返回sessionStale。每个Load用非敏感标记区分，并等待各自跨源终点后检查所有请求中的凭据。

## 测试夹具修正与复审

首个原生测试因错误引用事件中不存在的loadRequestId字段编译失败；改用实际session身份，编译失败独立保存，不作为产品缺陷复现。

Dart初版在失败状态到达后立即检查失败事件列表而误报。源代码确认native状态和失败事件分开发送、逐条确认，Dart里状态先完成milestone；改为在原定5秒内显式等待匹配事件，未修改产品时序或放宽门槛。

独立综合复审指出新Load的init请求入日志不能证明跳转链完成，合并两个会话的日志还可能由旧会话满足断言。增加逐Load标记及终点等待后，复测真实暴露第二链未完成：受控服务器对并行分段立即返回410，可能先使AVPlayer取消初始化预读。最终Dart夹具让分段响应等待该Load的初始化跳转终点；原生增加新loader完整Range探测，证据不依赖预读。针对修复只读复审通过。原始失败不删除，5秒等待期限不变。

本轮没有确认新的生产实现缺陷，仅新增验收及修复测试夹具。测试使用固定合成凭据和回环源。

## 统一验收

FINAL_RESULTS

首次Dart静态分析从错误目录调用导致路径不存在，正确目录检查另存。无线iPhone上的flutter test在启动前拒绝无线方式，其建议的--publish-port又不被test命令支持；切换已有flutter drive入口后构建/安装成功，但75秒内未发现Dart VM服务，手动中止未进入测试的会话。该中止退出0不视作测试通过。用户确认USB后首次Xcode仍显示network，随后再次连接被xcdevice确认为usb，所有记录保留。USB启动随后定位到Flutter缓存iproxy为x86_64，系统已有arm64版本；本轮进程专用AppContext包装仅替换精确iproxy路径并移除该子进程DYLD_LIBRARY_PATH，保持端口/UDID参数及所有测试行为，不改SDK或产品。兼容入口与二进制指纹也保留。

准备2秒、票据5秒、双8秒资格窗、955000bit/s、2次预算和500/1000ms退避未改。本轮没有长素材采集，不替代既有320宽/高档恢复失败。

## 台账与剩余项

生产源码哈希保持 `745362ff8d58a76ae2fe185ba8b91708b15c04a687f00ef3925363f02b463ba7`。台账只新增证据、更新后续行动，102行实施/验收状态不变，releaseReady=false。iOS CAP-ABR直接引用仍最多20个；上轮[Load生命周期与同候选取消报告](2026-10-28-ios-load-lifecycle.md)由本文索引并保留总表，不删除历史。

仍待：Dart完整并发凭据竞争、提交过程其他资源失败边界、原配置稳定自动恢复、暂停/跳转后640高档恢复、新帧空档和实际音画/字幕连续性，以及多设备/最低系统、DRM/Dolby授权资源。本轮顺序Load失败合约不能关闭整个ABR/DASH验收。旧终末停顿不恢复待办。

历史19组、4905个清单文件已核验未变。完整结果归档校验和台账检查记录见证据目录。未合并、推送、打标签或发布。
