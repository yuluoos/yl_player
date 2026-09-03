## 0.1.0-dev.1

- Define the app-facing controller and texture-only player view.
- Endorse the Android and iOS implementation packages.
- Add a runnable public API example.
- Add functional Android Media3 and iOS AVPlayer endorsed main paths.
- Bundle an experimental local-only iOS H.264/H.265 + AAC Matroska fallback;
  physical-device and memory acceptance remain release gates.
- Keep iOS HTTP-FLV, remote fallback containers, subtitles, and custom-header
  sources outside the implemented fallback boundary.
- Keep Dart resource teardown idempotent even when native disposal reports an
  error.
