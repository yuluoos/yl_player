import Foundation

struct NativePlayerError: Error, CustomStringConvertible, CustomDebugStringConvertible {
  let category: String
  let code: String
  let message: String
  var diagnostic: String?

  var description: String { YlAppleSafeDiagnostics.diagnostic(self) }
  var debugDescription: String { description }

  init(category: String, code: String, message: String, diagnostic: String? = nil) {
    self.category = category
    self.code = code
    self.message = message
    self.diagnostic = diagnostic
  }
}
