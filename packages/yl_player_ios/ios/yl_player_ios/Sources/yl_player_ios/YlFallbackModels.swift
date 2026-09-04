import Foundation

struct YlIosSourceDescriptor: Equatable {
  let uri: String
  let kind: String
  let formatHint: String
  let isLive: Bool
  let hasHeaders: Bool
}

enum YlFallbackContainer: Equatable {
  case matroska
  case flv
}

enum YlIosSourceRoute: Equatable {
  case avPlayer
  case headeredHls
  case localMatroska
  case networkMatroska
  case networkFlv
  case reject(category: String, code: String, message: String)

  var rejectionCode: String? {
    guard case let .reject(_, code, _) = self else { return nil }
    return code
  }
}
