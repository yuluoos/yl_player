# 独立 JavaScript 直播源解析模块实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Follow task-scoped independent review and final integration review.

**Goal:** 交付可选的 `yl_player_source_resolver` 模块，执行 mytvJS 同步宿主契约，提供可取消、有界的解析结果，并以三端实际运行和冻结九脚本受控测试验证。

**Architecture:** 固定 QuickJS 2026-06-04 原始源码，通过 Dart build hooks 编译相同 C 运行层。每次解析有独立 QuickJS runtime/context 和原生工作线程，原生中断处理器执行单调期限与取消，JS 堆/栈、输入/输出、请求数量和响应分别限额。同步 mytv 宿主函数通过有界单请求队列等待 Dart 异步传输；取消会唤醒宿主等待、关闭请求并等待原生释放后完成。播放器不依赖本模块，解析结果由业务显式交给内核。

**Tech Stack:** Dart 3.12 / Flutter >=3.44；QuickJS 2026-06-04 MIT；CryptoJS 4.2.0 MIT；Dart FFI + native_toolchain_c 0.19.2、hooks 2.0.2、code_assets 1.2.1。

**Spec:** [已授权需求](../specs/2026-09-20-playback-expansion-requirements.md) REQ-01/06/13/15、CAP-JS、REG-NET/LIFE/API/DIAG 与 ADR 0004/0005/0006。用户已授权根据文档实施并继续；本计划冻结普通工程选择，不改变 PD-01/02/03。

## Global Constraints

- Android API24、iOS15、macOS12 下限不变；不接入商业 SDK；无播放器内核 API/schema/SPI 变更。
- 保留所有上一批未提交变更，沿用功能分支；不自动提交、推送或发布。
- 不将下载成功、仅桌面 qjs 或 mock runtime 当三端 JS 执行通过。真实媒体播放与受控脚本兼容单列。
- 原始九脚本只在受控忽略目录保存，不写入 tracked 源码、日志或测试快照；哈希按原始字节，不能改写反混淆前导使测试通过。所有脚本宿主调用仅使用受控响应，不访问其实际下游服务。
- 原生 JS 无 std/os/文件/进程/模块加载器，网络只能经显式宿主队列；不使用 Future.timeout 代替执行终止。
- 安全错误不含脚本文本、URL、参数、请求头、返回的 error 文本或原生异常；稳定 code + 中文 message，取消与失败分开。
- 默认每次解析 10s，最大30s；脚本512KiB、参数8KiB、输出64KiB；JS堆默认16MiB、允许8–64MiB，栈默认512KiB、允许256KiB–1MiB；最多4个同时运行的原生任务；宿主单请求64KiB、单响应1MiB、总响应4MiB、最多8次请求，每请求最多5次重定向。脚本下载和宿主请求共用整体期限，各有容量限制；媒体 buffer.bounded 不涵盖这些预算。
- 网络限定HTTP(S)，无userinfo/fragment，自动重定向关闭；任何跨域后返回原域仍剥离凭据。本批全部脚本/调用方提供的头均按凭据处理，普通头不靠猜测放行；系统必要头由传输生成。无自动重试、cookie jar、环境代理、TLS校验绕过。
- main 参数保留原始裸 query 字符串；返回 JSON 字符串或对象均归一化。出现非空 error 优先于 url；过期时间仅接受本模块明确约定的 expiresAt（UTC ISO8601），九脚本未提供时为未知，不能从token推测。

## Native / Dart interface

Create `packages/yl_player_source_resolver/` with no dependency from `yl_player` itself. Dependencies are only FFI/build hooks and platform_interface for explicit HTTP playback conversion. Native worker bridge files `src/yl_script_runtime.h/.c`; pinned minimal QuickJS core under `src/quickjs/` (unmodified upstream license/hash manifest); `hook/build.dart`; private bindings `lib/src/native_runtime.dart`.

C opaque job and ownership API (all buffers copied at entry; returned copies freed by `yl_js_free`; status published only after runtime/context destruction):

```c
typedef struct yl_js_job yl_js_job;
yl_js_job *yl_js_start(const char *source, size_t source_len,
  const char *parameter, size_t parameter_len, uint32_t timeout_ms,
  size_t heap_bytes, size_t stack_bytes);
int yl_js_status(yl_js_job *job); // 0 running, 1 success, 2 timeout, 3 cancelled,
  // 4 resource limit, 5 syntax, 6 execution, 7 host API unsupported, 8 invalid result,
  // 9 host transport failure (safe classification separately transported in Dart).
char *yl_js_take_request(yl_js_job *job); // at most once per request; UTF8 JSON {method,args}
int yl_js_reply(yl_js_job *job, const char *json, size_t len, int error_code);
char *yl_js_result(yl_js_job *job); // completed JSON result copy, NULL otherwise
void yl_js_cancel(yl_js_job *job);
int yl_js_destroy(yl_js_job *job); // succeeds only terminal; joins completed worker then frees
void yl_js_free(void *buffer);
```

All C exported symbols visibility explicit. Thread holds no Dart callbacks. Request queue permits one outstanding synchronous call and validates response state; lock/cond never waits with caller-owned memory. Terminal status cannot precede worker cleanup. Native global admission counts decrement on completed worker exit, pointer remains caller-owned until destroy. QuickJS errors map by fixed interruption/resource flags and execution stage; no raw exception extraction. Unhandled stack-limit exceptions map to generic execution failure because a script can also explicitly construct InternalError; caught JavaScript exceptions may recover while all native limits remain enforced. Limits checked independently in C so direct FFI misuse is bounded.

Native prelude installs `mytv.get(url,headers?)`, `fetch(url)`, `post(url,headers,body)`, `request(url,method,headers,body?)`, no-op `log` (no arbitrary logging), and explicit unsupported missing-member trap. Global `parseItems(query)` handles query pairs, first equals split, percent decoding, plus-as-space, last duplicate wins, null prototype. Original main still receives unmodified parameter. Unsupported percent syntax fails safe. CryptoJS bundle evaluated before user source within same runtime and budgets. main may return synchronously or a Promise: drain bounded QuickJS jobs; pending Promise with no work ends with invalid_result (no timer host provided).

Dart API files `lib/yl_player_source_resolver.dart`, `lib/src/script_models.dart`, `lib/src/script_resolver.dart`, `lib/src/script_http.dart`:

```dart
final class YlScriptReference {
  YlScriptReference({required Uri scriptUri, required String parameters,
    Map<String, String> headers = const {}});
  factory YlScriptReference.parse(String reference); // javascript://https://.../file.js?id=...
}
final class YlScriptLimits { /* validated immutable named limits matching above */ }
final class YlResolvedSource {
  Uri get uri;
  Map<String,String> get headers;
  DateTime? get expiresAt;
  YlNetworkSource toNetworkSource(); // HTTP(S) only, live, all supplied headers credentials
}
final class YlScriptException implements Exception {
  String get code; String get message; bool get retryable;
  String get phase; String get diagnosticId;
  // safe toString; fixed phase and per-resolution correlation, never user payload
}
final class YlScriptResolution {
  Future<YlResolvedSource> get result;
  Future<void> cancel(); // returns only after transport + native cleanup
}
final class YlScriptResolver {
  YlScriptResolver({YlScriptLimits limits = const YlScriptLimits()});
  YlScriptResolution resolve(YlScriptReference reference);
  YlScriptResolution resolveSource(String source, {String parameters = ''});
  Future<void> dispose(); // cancels and awaits all owned jobs
}
```

Multiple handles independent; no global latest-channel result auto-publication. Explicit past expiresAt rejects as script.expired before media conversion; absent expiry remains unknown. Caller cancels prior handle when changing channel; a cancelled handle never resolves success even if cancellation races native result. Refresh is explicit repeat resolve; no hidden timer or automatic media replacement. Media result protocols HTTP/HTTPS/RTMP/RTMPS can be represented, but toNetworkSource rejects RTMP variants until kernel supports them. Untrusted URL/headers and exception objects have redacted toString.

## Task 1: 可终止的原生运行层与构建接入

**Files:** new package pubspec/LICENSE/README baseline, root pubspec workspace entry+lock, `src/quickjs/*`, provenance/license, `src/yl_script_runtime.h/.c`, `hook/build.dart`, `lib/src/native_runtime.dart`, focused `test/native_runtime_test.dart`. Task1 may implement prelude without CryptoJS; Task2 supplies pinned CryptoJS initialization without changing API.

- [x] Save phase baseline; pin official QuickJS archive SHA256 `b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a`. Use only core sources/headers required for embedded VM; omit libc/std/os CLI. Hook compiles Android/iOS/macOS, target floors inherited; unsupported OS explicit.
- [x] RED real C/runtime tests before implementation: evaluate `function main(p){return JSON.stringify({url:'https://example.invalid/'+p})}`; `while(true){}` timeout; started infinite loop cancel; allocation exhaustion; recursive overflow; catastrophic regex timeout; `mytv.get` request/reply; cancellation during held host request; repeated cleanup/admission reuse; JS syntax and thrown secret redact. Stub runs must fail assertions, not compilation.
- [x] Implement API above. Monotonic native deadline and atomic cancellation checked in QuickJS interrupt and timed condition waits; job status becomes terminal only after context/runtime free. Source/parameter/output/queue bytes bounded. No native callback on Dart isolate. Preserve structured object or string result as JSON and safe statuses.
- [x] Dart private handle starts native worker, polls without blocking UI, copies/frees request/result buffers, supports idempotent cancel and close; no user-facing API until Task2. Tests exercise actual compiled runtime, not a command-line process substitute.
- [x] Build/test macOS through native hook, compile C core for iOS Simulator and Android arm64 target or defer actual target hook builds to Task3 with explicit dependency. Run ASan/UBSan native harness for lifecycle/bounds if available; report observed tests and any tool/platform limitation.
- [x] Self-review, report exact RED/GREEN and source hash verification. Independent scoped review before Task2. No commits in this existing uncommitted delivery.

## Task 2: mytvJS 配套模块、受控请求与结果归一化

**Files:** package public export/model/resolver/http files above, `src/cryptojs` pinned MIT bundle + generated include if needed, tests `script_models_test.dart`, `script_resolver_test.dart`, `script_http_test.dart`; root docs report/compatibility owned by coordinator. Existing player untouched.

- [x] RED public tests parse javascript references without losing query bytes, invalid source/userinfo/oversize, actual sync mytv request and JSON results, error+url precedence, header-list normalization/CRLF rejection, unknown expiry, explicit refresh, output protocols and HTTP-only conversion, unsupported host API and raw-secret error suppression.
- [x] Fetch/pin official CryptoJS4.2.0 upstream and record raw checksum/license; embed in QuickJS global scope. Test known MD5/HmacSHA256 and AES-CBC/Pkcs7 vectors through same native runtime. Scripts cannot load arbitrary native modules or access Dart/globalhost state.
- [x] Implement one per-resolution owned Dart HttpClient with explicit redirect loop, sticky credential strip, total deadline, bounded source/body/count and no retries. HTTP get/fetch/post return body text; request returns {code,body}. Header arrays parse first colon only, coalesce case-insensitive duplicates with identical trimmed values, reject conflicting duplicates or invalid entries/forbidden connection/framing controls; supplied Host must match the initial request URI hostname and any explicitly supplied port (an omitted port is normalized from the URI), is then discarded and generated by transport for each hop (mismatch rejects); incoming Content-Length is validated but computed by transport. Host transport replaces supplied Accept-Encoding with supported gzip and counts decompressed body bytes. All non-2xx for get/fetch/post produce fixed known HTTP error (403 is explicit forbidden/nonretryable); request exposes code for script-owned decisions. Never bypass global count/redirect budget on script retry.
- [x] RED/GREEN loopback tests A→B→A no credential restoration, sameorigin credential retention, request403 vs get403, POST exact body/no implicit retry, held headers/body cancel, oversize/call budget, timeout cleanup, cancellation-after-result race and resolver dispose. Network adapter injectable only via private testing seam; no public bypass of default guarantees.
- [x] Execute all nine frozen original scripts with controlled in-memory host responses, zero real downstream requests, preserving exact bytes; safe report per-script main inputs/calls/results and parseItems/crypto contracts. This may use private transport seam in a harness generated from controlled ignored archive; repo keeps only hash IDs and synthetic fixtures, not original scripts or actual source URLs. Compatibility failures must be fixed or explicitly carried as uncompleted gates, not replaced scripts.
- [x] Scoped Dart analyze/format, focused package tests and native changes covering tests once, independent task review.

## Task 3: 三端实际运行与解析结果交给内核

**Files:** package example minimal Flutter app (separate from player example so optional dependency remains explicit), `integration_test/script_runtime_test.dart`, controlled sample harness generator under `tool/`, provenance/safe matrix and permanent report `docs/superpowers/reports/2026-09-22-script-resolver.md`.

- [x] Build hook + actual FFI runtime on macOS/iOS Simulator/Android API36, serialized native builds. Public successful parse, infinite JS timeout, regex timeout, live cancel, held HTTP cancel, memory failure and reuse aftercleanup must execute in app, not only host unit tests.
- [x] Nine frozen scripts controlled compatibility matrix on each platform using generated ignored local test fixture; no remote downstream request. Require expected synthetic media URI/headers and per-script applicable invalid/missing input, host-failure/malformed-reply, timeout/cancel and explicit refresh checks (scripts with no host calls record host cases not applicable); input versions stay frozen.
- [x] At least one controlled JS result hands HTTP source to actual yl_player, renders matching-session firstFrame and stops cleanly. Use existing synthetic local media fixtures; direct RTMP result reports unsupported conversion honestly. Kernel RTMP is not implemented by resolver.
- [x] Restore normal generated app configs, close only task-owned devices/processes; no repeated full suites unless changes/failures justify. Update package README/example, architecture/compatibility/report with actual pass counts, limitations, archive retrieve/hash checks and remaining requirements. User business live_player_controller path still unavailable: do not claim end-to-end subscription integration.
- [x] Task3 independent review and final phase integration review no blocking findings. Retain uncommitted evidence and baselines; full broader upgrade still pending.

## 方案选择与边界

系统 WebView/JSC 分平台实现会引入不同的终止/堆限制与宿主语义；直接使用 CLI 不适用于移动端；选择同版本可嵌入 QuickJS，增加一份开源 C 依赖以取得一致的运行层。官方文档说明堆/栈限制与中断处理器；本地2026-06-04源码 libregexp 有 timeout polling，但仍需真实正则/循环/分配测试确认，不凭文档宣称硬实时上界。

本批不自动切台、不自动刷新媒体、不改变播放器协议支持、不推进 PD 产品取舍。原始脚本没有显式有效期时结果保持未知；取消、期限、已证实的堆/队列容量超限和 Dart 宿主失败为终止状态，不能被脚本 catch 转成成功。普通可捕获 JS 异常（含引擎栈限制异常）允许恢复，但仍受栈、堆和整体期限约束；未捕获栈异常不能仅凭 InternalError 类型猜成资源故障。本模块是同进程受限运行时，不宣称抵御所有原生引擎漏洞的进程级安全隔离。

来源：[QuickJS 官方文档](https://bellard.org/quickjs/quickjs.html)、[Dart FFI/build hooks](https://dart.dev/interop/c-interop)。
