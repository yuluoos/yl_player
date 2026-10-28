# iOS 准备期间意图撤销修复与 seek 验证

基线 `af3d138c`，当前本地分支 `codex/abr-recovery`。本轮仅诊断夹具、镜像及工具修改，承接[候选预滚报告](2026-10-28-ios-item-preroll.md)。[完整证据](evidence/2026-10-28-ios-preparation-intent/)保留全部红灯、原始采样、源码身份、完整xcresult及复核记录。不发布。

## 已确认问题与改动

元数据候选仅在准备前检查票据，进入loadMetadata后只看Task取消和期限。票据在真实resource-loader请求挂起后失效，旧实现仍等待2秒期限，返回timedOut。真机 `intent-red` 1失败/0通过，明确断言timedOut不是cancelled。这是诊断准备的取消缺口，不是历史终末停顿的根因证明。

修复在开始、每轮轮询及返回loaded之前重验授权，失效即取消asset加载并释放owned loader请求。保留原2秒期限、原票据5秒有效期和最终旧item/票据复核。新回归在真实请求进入后撤销意图，要求取消通知1秒内到达，且pending=0、owner取消一次、已终止请求数大于0。另测开始前拒绝不发起加载、任务取消与既有超时路径。

预滚helper新增仅供诊断的阶段回调，真实本地mp4等待ready并发出精确seek或preroll请求之后撤销。两阶段均返回cancelled、detach、没有可安装item、资源清理一次。这是请求已发出边界的覆盖，不能代表所有异步竞态或物理输出连续性。

新增两个严格匹配模式的场景：pause-during-metadata仅asset-metadata，在元数据加载调用已发出后暂停/作废首票，2秒后恢复；seek-during-preparation仅asset-preroll，在候选实际ready后先作废首票，再让旧backend向前seek1秒。记录调用是否成功、时刻和目标。元数据注入不保证网络请求已经抵达，实际挂起请求取消由独立原生测试证明。seek调用成功也不等于落点验证，必须结合帧采样。

Python模式不匹配红灯1方法4子失败保留，修复后完整accesslog定向26通过。原生green四方法通过/0失败/0跳过，其中三项新增，一项为既有超时/失败覆盖。镜像声明iOS835/macOS879，声明数不等于执行数。

## 真机采集

沿用授权开发签名，iPhone16（iPhone17,3）/iOS27.2。同一构建预登记四轮顺序；原配置与独立诊断配置分别保存，不以诊断配置代替原配置验收。素材120秒、原生140秒、采集240秒。采集passed只表示该探针完成，注入未实际发生时仍未验证。

| 运行 | 采集passed | 位置（秒） | 票据与准备 | 替换边界新帧间隔 |
| --- | --- | --- | --- | --- |
| original-1 | True | 120.023381 | 零票据 | 无替换 |
| metadata-pause | True | 120.019488 | 1:preparationFailed / cancelled；2:installed / loaded | 273.336ms，清空0 |
| preroll-seek | True | 120.029332 | 1:preparationFailed / cancelled；2:installed / ready | 225.516ms，清空0 |
| original-2 | True | 120.023887 | 零票据 | 无替换 |

original-1：片尾120.023381秒，窗口bitrate=1065610，票据0张。完整策略原因与代理边界见intent-proof.json；本轮未复现历史63.900秒终末停顿，不能据此宣布修复。

original-2：片尾120.023887秒，窗口bitrate=852447,690304,658792,746471,802263,842601,881858,785446,681510，票据0张。完整策略原因与代理边界见intent-proof.json；本轮未复现历史63.900秒终末停顿，不能据此宣布修复。

metadata-pause首票：metadataPauseApplied=True，warmup=cancelled，外层结果=preparationFailed，旧item保留=True；候选代理接收0次、活动任务0、待发送0。本轮共2张票据，源级预算未退回。全程最大新帧间隔2133.070ms，不能只报告替换边界。

此媒体注入发生在代理接收请求之前；真实在途请求取消由intent-green原生挂起请求测试单独覆盖。

preroll-seek首票：preparationSeekApplied=True，warmup=cancelled，外层结果=preparationFailed，旧item保留=True；候选代理接收8次、活动任务0、待发送0。本轮共2张票据，源级预算未退回。全程最大新帧间隔350.518ms，不能只报告替换边界。

用户seek目标34007ms；旧generation=0在elapsed=33.643170秒出现新帧提交，同条采样的播放时钟为34.007000秒，在调用后1秒内且目标后250ms范围内。旧恢复票据取消，未用它替换item；这是采样落点证据，不是物理音画或所有seek竞态验收。

原配置1在首窗合格后、第二8秒窗完成前已自然升高档；原配置2九个完整窗658792–881858bit/s全部低于955000，故零票据符合冻结规则。没有满足原双窗口条件却漏触发的证据。

连续性、物理输出与音画同步验收标志仍为false。主动暂停、用户seek与替换间隔分别记录，不能将其中一次较短间隔泛化为连续性或性能改善。

原冻结配置哈希 `4e4f256c59465f4a573d6ab1c48f7a7571294638025088d0cddba9325f5032ea`；零延迟诊断配置 `9f63acdf1ab0ce92c5565bc3a750478f0c6c5ba76cef88c7e1092cfcd89b01f1`。先高后低、有逾期、至少5秒连续缓冲、至少20秒剩余、两个8秒窗/每窗3请求/955000bit/s、源级两次预算与500/1000ms退避不变。取消不退预算，未将旧纹理算作新帧，也未放宽精确seek。

## 集中验收与台账

最终iPhone七类170项、macOS六类145项通过，均0失败/0跳过。范围为DASH loader、Apple session/publication、network byte source、platform services、nonblocking metadata，以及仅iOS存在的live reconnect；完整测试树与类计数保存。网络工具115项、benchmark全发现294项（含15项台账测试）、镜像/固定历史来源及diff检查通过。无媒体环境的探针不会进行媒体测试，四轮媒体另列。未将受影响范围回归当作完整Dart/Android/全部Apple/独立消费者验收。

12组历史证据3010个清单文件逐一校验未变。本轮生产源码身份仍为 `9fd66d341470a59bbc1eca827c85f52e63b81766ce7a0f361477e1abe7db8064`，诊断源码/制品身份单独记录。运行与构建警告保留，未声称已消除。

独立综合复审完成，无阻断发现。复审核实196条归档清单、179条原始映射，并将8份完整xcresult共2516个普通文件与原始bundle逐一比对，路径和内容一致；macOS包73199847字节分5块保存，未删附件。后续复审记录及最终台账复核追加到清单。结构检查通过，台账及性能registry的require-ready均保留退出1；不以源码身份匹配代替发布就绪。

用户收尾指令：“旧终末停顿 不再保留”。据此将旧63.900秒终末停顿移出当前未完成清单及台账后续行动，不再追踪或作为当前待办阻塞项。以上采集观察及原始失败仍作为历史证据，不将取消跟踪等同于修复通过。该决定取代前轮报告对此项的待办描述。

仍保留：原配置稳定安全自动恢复、缩短替换新帧空档、真实物理路由断开、完整凭据/约束及其他准备阶段竞争、物理音画/字幕连续性、auto/caps/fixed完整矩阵、多设备/最低系统、DRM/Dolby授权及外接输出、历史iOS33失败/1skip。当前预滚方案没有已确认性能收益，生产自动策略未接入。

台账只增加报告/待办，102行全部implementation/verification/acceptance状态保持：67 implemented / 34 partial / 1 unreviewed，69 not_run / 30 external_missing / 3 failed / 0 passed。releaseReady=false。仅本地提交，不合并、不推送、不打标签、不发布。
