import Foundation
struct NativePlayerError: Error { let category: String; let code: String; let message: String; var diagnostic: String? }
enum YlAirPlayRemux {
  static func failure(_ code: String, _ message: String, diagnostic: String? = nil) -> NativePlayerError {
    NativePlayerError(category: "airplay", code: code, message: message, diagnostic: diagnostic)
  }
}
