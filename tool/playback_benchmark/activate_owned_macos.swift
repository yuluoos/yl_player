import AppKit
import Foundation
let pid = pid_t(CommandLine.arguments[1])!
let expected = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
let matches = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == expected }
guard matches.count == 1, matches[0].processIdentifier == pid else { fatalError("Expected exactly the owned test runner") }
let before = ProcessInfo.processInfo.systemUptime
let config = NSWorkspace.OpenConfiguration()
config.activates = true
config.createsNewApplicationInstance = false
config.addsToRecentItems = false
var done = false
NSWorkspace.shared.openApplication(at: expected, configuration: config) { app, error in
  let after = ProcessInfo.processInfo.systemUptime
  print("pid=\(app?.processIdentifier ?? 0) requested=\(before) returned=\(after) error=\(String(describing: error)) active=\(app?.isActive ?? false) sameOwnedPID=\(app?.processIdentifier == pid)")
  done = true
}
let deadline = Date(timeIntervalSinceNow: 5)
while !done && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
if !done { exit(2) }
