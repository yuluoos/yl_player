import Foundation

struct NativePlayerError: Error {
  let category: String
  let code: String
  let message: String
  var diagnostic: String?

  init(category: String, code: String, message: String, diagnostic: String? = nil) {
    self.category = category
    self.code = code
    self.message = message
    self.diagnostic = diagnostic
  }
}
