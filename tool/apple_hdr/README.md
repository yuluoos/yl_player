# Apple HDR verification

`policy_tests.swift` checks that DV/PQ/HLG retain 10-bit output and SDR stays 8-bit.
`sample_tests.swift` checks original image identity, PQ/RPU attachments, immediate
presentation and sample-owned memory reservation lifetime. `mailbox_tests.swift`
checks frame coalescing, clear ordering, disposal and old-error epoch invalidation.
`lease_tests.swift` checks the real lease/output implementations with small test
ports. Run the local tests on macOS with Xcode command-line tools:

```sh
sh tool/apple_hdr/run_tests.sh
```

CoreVideo's IOSurface tests need normal host permissions; a sandbox that denies
IOSurface access can fail allocation before the test assertions are reached.

`mac_display_probe.swift` is an opt-in native window using the production metadata
bridge, output precision policy and sample renderer. It accepts a local media file
and an extracted/repaired hvcC configuration. Neither media nor credentials belong
in this directory. Compile it together with `YlHDRVideoPolicy.swift`,
`YlVideoSurfaceMailbox.swift` and `YlSampleBufferVideoRenderer.swift`, linking the
macOS slice of `YlFFmpegBridge.xcframework`; run with that framework on
`DYLD_FRAMEWORK_PATH`. Arguments: `MEDIA_PATH REPAIRED_HVCC_PATH`.

The probe validates one frame, RPU retention and display-layer acceptance. It does
not certify color correctness, active EDR, sustained playback or the iOS platform
view. A dark first frame is insufficient for visual acceptance. The macOS plugin now negotiates AppKitView for HDR; the standalone probe alone
does not exercise Flutter embedding or sustained application playback.
