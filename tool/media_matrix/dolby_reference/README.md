# Independent Dolby PCM reference on macOS

This offline check decodes the two owned catalog tracks with the packaged Dolby
bridge and a pinned OxideAV build. FFmpeg only copies compressed packets for
the independent check. Each copy must match its original demuxed packet hash.
Both decoders receive the same ordered packets. The comparator uses the first
packet PTS to index each archived public PCM window at 48 kHz. It checks all
channels, including LFE, in WAVE speaker order. The existing absolute error
limit is 0.0002 for every normalized sample.

From the repository root, prepare the standalone reference in a new directory:

```sh
ref=build/dolby-reference-replay
git clone https://github.com/OxideAV/oxideav-ac3.git "$ref"
git -C "$ref" checkout --detach 1a2e96db770d5d113811d97df3a59e1dbfc2bb5f
cp tool/media_matrix/dolby_reference/yl_reference.rs "$ref/examples/"
cp tool/media_matrix/dolby_reference/Cargo.lock "$ref/"
cargo build --locked --release --manifest-path "$ref/Cargo.toml" --example yl_reference
```

The upstream manifest declares Rust 1.95. The recorded run used Homebrew Rust
1.94.0 with Cargo's `--ignore-rust-version` and compiled successfully. Run the
comparison with a fresh output path:

```sh
app=build/macos-format-matrix-20261103/final-aot-matrix.app
python3 -B tool/media_matrix/dolby_reference/verify.py \
  "$app/Contents/Frameworks/YlFFmpegBridge.framework/YlFFmpegBridge" \
  "$ref/target/release/examples/yl_reference" \
  docs/superpowers/reports/evidence/2026-11-03-macos-qualified-format-matrix/final-matrix \
  build/dolby-independent-result.json
```

The receipt covers the complete raw decode and the previously captured public
file and HTTP windows. The reference executable is a test tool and is built
outside the player packages.
