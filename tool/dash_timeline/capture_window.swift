import AppKit
import CoreGraphics

// Owned example window only. Never enumerate or print unrelated window contents.
let bundle = "dev.ylplayer.ylPlayerExample"
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
fputs("captureAllowed=\(CGPreflightScreenCaptureAccess()) ownedApps=\(apps.count)\n", stderr)
guard CGPreflightScreenCaptureAccess(), apps.count == 1, let app = apps.first else { exit(2) }
app.activate(options: [])
let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
let owned = windows.filter {
  ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier &&
    ($0[kCGWindowLayer as String] as? Int) == 0 &&
    (($0[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double ?? 0) > 100
}
func area(_ value: [String: Any]) -> Double {
  let bounds = value[kCGWindowBounds as String] as? [String: Any] ?? [:]
  return (bounds["Width"] as? Double ?? 0) * (bounds["Height"] as? Double ?? 0)
}
let sorted = owned.sorted { area($0) > area($1) }
fputs("ownedWindows=\(owned.count) areas=\(sorted.map(area))\n", stderr)
guard let main = sorted.first, sorted.count == 1 || area(main) > area(sorted[1]),
      let id = main[kCGWindowNumber as String] as? Int else { exit(3) }
print(id)
