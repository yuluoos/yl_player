import Foundation

public struct NativePlayerError: Error, CustomStringConvertible, CustomDebugStringConvertible {
  public let category: String
  public let code: String
  public let message: String
  public var diagnostic: String?

  public var description: String { "Playback operation failed." }
  public var debugDescription: String { description }

  public init(category: String, code: String, message: String, diagnostic: String? = nil) {
    self.category = category
    self.code = code
    self.message = message
    self.diagnostic = diagnostic
  }
}
