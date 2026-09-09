import Foundation
import QuartzCore

enum YlAppleSafeDiagnostics {
  private static let epoch = CACurrentMediaTime()
  static func nowMilliseconds() -> Int64 {
    max(0, Int64((CACurrentMediaTime() - epoch) * 1000))
  }
  static func identifier() -> String { "apple-" + UUID().uuidString.lowercased() }
}
