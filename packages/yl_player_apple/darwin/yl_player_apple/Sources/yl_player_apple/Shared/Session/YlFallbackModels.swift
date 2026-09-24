import Foundation

enum YlAppleSourceRoute: Equatable {
  case inspect
  case avPlayer
  case dashHls
  case headeredHls
  case localMatroska
  case networkMatroska
  case networkFlv
  case networkRtmp
  case reject(category: String, code: String, message: String)

  var rejectionCode: String? {
    guard case let .reject(_, code, _) = self else { return nil }
    return code
  }
}
