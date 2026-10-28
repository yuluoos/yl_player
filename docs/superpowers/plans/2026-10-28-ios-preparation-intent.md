# iOS 准备期间意图撤销 Implementation Plan

> 使用 executing-plans 在当前工作树直接实施；沿用用户持续实施和集中验收授权，一次最终独立综合复审。

**Goal:** 补齐诊断候选在元数据加载、seek/preroll请求已发出时的撤销，并真机验证较新seek不被旧恢复票据覆盖。
**Architecture:** 继续沿用现有Swift诊断夹具和Python采集器。元数据准备增加allowed复核，与预滚相同地终止失效准备；阶段注入只在测试夹具，生产自动策略不接入。
**Tech Stack:** Swift/XCTest/AVFoundation，Python unittest，已连接iPhone与macOS。
**Spec:** ../reports/2026-10-28-ios-item-preroll.md 的保留未完成项与用户继续实施指令。

## Constraints

基线af3d138c。原120秒素材、140/240秒期限；双8秒窗、3请求/955000bit/s、5秒缓冲、20秒剩余、2预算与500/1000ms退避均不变。准备最多2秒并受票据5秒有效期限制。保留全部失败，不发布、不合并、不推送。

## Review Focus

失效意图不继续加载；任务取消/超时释放实际请求；seek/preroll已开始仍能取消；新seek不被旧票据覆盖；未实际注入不得记为验证通过。凭据/约束的完整竞争矩阵与物理连续性继续保留。旧63.900秒停顿按用户收尾指令移出后续待办，原始证据不改。

## Tasks

- [x] canonical YlDashResourceLoaderTests.swift 新增真实挂起元数据请求撤销测试，先以ignored allowed参数观察红灯，再修复开始/每轮/成功前检查，原超时不变。增加已发出seek/preroll的阶段回调和真实本地媒体撤销验证，镜像同步。
- [x] Python先写拒绝不匹配场景/模式红灯；增加pause-during-metadata（仅asset-metadata）、seek-during-preparation（仅asset-preroll）及逐行回显校验。原生记录实际注入、目标位置、取消资源和票据结果，失败不能用try?伪装成功。
- [x] 定向测试通过后同一构建预登记顺序：原配置normal、metadata-pause、preroll-seek、原配置normal。采样源/制品身份固定，失败保留后分析；不争用设备/构建。
- [x] 统一iPhone/macOS受影响原生七/六类、network/benchmark全发现入口、镜像/台账；独立综合复审、原失败及完整xcresult归档、更新台账而不提升完整验收状态，本地提交。

Ruling: 本轮先处理已确认的诊断元数据取消缺口，并扩展真实阶段/seek验证；不为猜测中的终末停顿修改生产策略，不重复无收益的预滚性能探索。原配置两轮只记录是否复现，不能以未复现宣布修复。

检查点：af3d138c..当前工作树；定向红绿、四轮媒体、170/145原生、115/294工具及独立复审完成。剩余项见报告，完整能力未验收。
