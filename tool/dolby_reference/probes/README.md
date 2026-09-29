# 固定候选构建与输入探针（Task1B1）

探针只用于研究，不链接到播放器或发布包。`../build-evidence.json` 保存6个arm64库、工具链、固定源码归档/子模块及日志哈希。iOS/Android只构建与链接；macOS实际运行。缺失研究目录时必须先准备依赖，不能把没有执行当通过。

本次工作目录为仓库根下 `.superpowers/sdd/2026-09-26-remaining-07-dolby/build-probes`（Git忽略）。原始媒体与所有构建产物留在该目录，不提交库/视频。下载按官方归档URL和SHA-256核验，不能改用浮动版本。Cargo使用原始锁文件和独立 `cargo-home`，Python虚拟环境使用Meson1.7.2/Ninja1.11.1.3/Jinja2 3.1.6/MarkupSafe3.0.3。

## libdovi

源码 `dovi_tool-614c816b6446dcd1dbaf433403d499a6026fbb5a/dolby_vision`，lib3.4.0。没有构建需要Rust1.95的dovi_tool CLI。三个静态库使用官方Rust1.94.0及对应标准库；归档校验和见证据。Homebrew同版本与官方std的ABI不能混用，且本机Homebrew std带macOS26下限，未采用其产物。

从仓库根设置（按本机路径调整）：

```sh
p07_root="$PWD/.superpowers/sdd/2026-09-26-remaining-07-dolby/build-probes"
export CARGO_HOME="$p07_root/cargo-home"
export RUSTC="$p07_root/rust-sysroot/bin/rustc"
# target依次为aarch64-apple-darwin、aarch64-apple-ios、aarch64-linux-android；
# 每个target使用独立CARGO_TARGET_DIR。iOS命令另设IPHONEOS_DEPLOYMENT_TARGET=15.0。
CARGO_TARGET_DIR="$p07_root/reproduce-macos" cargo rustc --locked \
  --manifest-path "$p07_root/dovi_tool-614c816b6446dcd1dbaf433403d499a6026fbb5a/dolby_vision/Cargo.toml" \
  --lib --features capi --release --crate-type staticlib --target aarch64-apple-darwin
```

macOS不要给主机proc-macro构建强加 `MACOSX_DEPLOYMENT_TARGET=12`：当前Xcode27组合曾产生mis-aligned LINKEDIT的主机插件，已记录失败。使用官方标准库默认目标，再对消费者以macOS12链接并检查实际Mach-O下限；最终链接无较高系统版本警告。这不是修改包部署下限。

`libdovi_smoke.c` 按固定CAPI签名验证空指针拒绝与原始UNSPEC62 RPU解析/释放。最多64KiB输入，错误不输出库内部原文。macOS链接命令：

```sh
xcrun clang -mmacosx-version-min=12.0 tool/dolby_reference/probes/libdovi_smoke.c \
  "$p07_root/official-macos-final/aarch64-apple-darwin/release/libdolby_vision.a" \
  -framework Security -framework CoreFoundation -liconv -o "$p07_root/libdovi-smoke-macos-final"
"$p07_root/libdovi-smoke-macos-final" "$p07_root/sample-first-rpu.bin"
```

iOS链接使用Xcode iphoneos clang、`-target arm64-apple-ios15.0 -isysroot <iphoneos SDK>`及同样framework/iconv；Android使用NDK28.2.13676358的`aarch64-linux-android24-clang`和`-ldl -lm -llog`。iOS产物LC_BUILD_VERSION=15.0、macOS=12.0；Android产物为aarch64 ELF/`/system/bin/linker64`。仍需最低系统设备运行，不以链接成功宣称兼容性完全通过。

本次macOS原始RPU成功、缺参数/空文件/超限/无效RPU共5个退出预期全部匹配；上游库 `cargo test --locked --manifest-path .../dolby_vision/Cargo.toml --lib --features capi` 的2个单元测试通过（该测试运行使用初始Homebrew Rust，最终库使用官方工具链）。

## libplacebo

源码固定 `c42968d8616a1d1c8ad5f4f1a8d6f5a9cb396e56`，版本7.372.0，源码未补丁。恢复同提交的glad、fast_float、Vulkan-Headers子模块，归档hash见证据。关闭Vulkan仍需要其接口头用于stubs。

共同Meson参数：`-Dvulkan=disabled -Dopengl=enabled -Dd3d11=disabled -Ddovi=enabled -Dlibdovi=disabled -Dlcms=disabled -Dxxhash=disabled -Dunwind=disabled -Ddemos=false -Dbench=false`。只在macOS设`-Dtests=true`；跨端设false并关闭glslang/shaderc。这是OpenGL/Dolby候选，不是Vulkan、直接Metal或libdovi联合集成。

macOS C/C++编译与链接参数为`-mmacosx-version-min=12.0`，为上游头文件测试增加实际 `pkg-config --variable=includedir dav1d` 返回的路径；不修改测试断言。xxhash为可选缓存哈希，关闭它解决该固定版本测试漏include问题，不关闭FEL处理。

跨端ini由 `[binaries]` 指定Xcode/NDK C、C++、ar、strip；`[host_machine]` 使用aarch64/little及darwin或android；`[properties]` 设置`needs_exe_wrapper=true`和指向空目录的`pkg_config_libdir`，同时清空PKG_CONFIG_PATH防止主机库混入。iOS四组c/cpp及link参数均为`-target arm64-apple-ios15.0 -isysroot <iphoneos SDK>`，Android使用NDK API24 wrapper。实际ini保存在研究目录，不能把本机绝对路径作为项目配置。

```sh
# 用记录的参数先meson setup；重新配置需同时提供build和source目录。
PATH="$p07_root/venv/bin:$PATH" meson compile -C "$p07_root/placebo-macos"
PATH="$p07_root/venv/bin:$PATH" meson test -C "$p07_root/placebo-macos" --no-rebuild --print-errorlogs
```

三端构建退出0；macOS13通过、1跳过（opengl_surfaceless.c，退出77）。该GPU测试没有执行；其他13项不证明实际FEL合成画质。iOS/Android未运行，shader执行、输出精度、平台视图和设备能力仍待验证。

## 原始输入与盘点

SolLevante by Netflix, Inc.; Dolby, Inc. modified version。发布方随附说明声明CC BY 4.0：[署名说明](https://github.com/DolbyLaboratories/dolby-vision-contents/blob/957c53ac160e11ae581aa1f4fe811a8ad6cf27df/SolLevante_Netflix/SolLevante%20by%20Netflix.docx)，[许可证](https://creativecommons.org/licenses/by/4.0/)。下载的MP4未修改；抽取的首个RPU是解析衍生物。媒体hash、字节数和署名保存在 `../sample-observation.json`。

FFmpeg/ffprobe8.0.1只用于离线样本盘点，不替换播放器9.0.1桥接。`ffprobe -show_streams` 确认P5、1920×1080、24fps；copy+hevc_mp4toannexb抽取首access unit后取NAL type62，未改写RPU内容。`inspect_rpu.rs` 使用固定libdovi的serde功能及serde_json1.0.150输出首RPU解析结果，独立Cargo工程/锁文件留在研究目录。实际结果为CM2.9块、L1/L2/L4/L5/L6，含非默认L2 trim；只检查首RPU，不推断全片元数据或所有帧正确。

目前没有独立目标参考图、最终容差或原始P7 FEL，因此不升级 `cases.json` 的历史调查行。新输入观察是补充证据，并不表示Task1整体结束、完整映射或原生DV信号通过。
