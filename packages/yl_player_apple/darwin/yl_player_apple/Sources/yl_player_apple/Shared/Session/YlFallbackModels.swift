import Foundation

enum YlAppleSourceRoute: Equatable {
  case inspect
  case avPlayer
  case fairPlay
  case dashHls
  case dashProgram
  case headeredHls
  case localMatroska
  case networkMatroska
  case networkFlv
  case networkRtmp
  case avi
  case transportStream
  case reject(category: String, code: String, message: String)

  var rejectionCode: String? {
    guard case let .reject(_, code, _) = self else { return nil }
    return code
  }
}
