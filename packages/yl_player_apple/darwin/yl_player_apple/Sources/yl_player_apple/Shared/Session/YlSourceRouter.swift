import Foundation

/// Compatibility name for internal route queries, with one pure authority.
enum YlSourceRouter {
  static func route(_ source: YlAppleSourceDescriptor) -> YlAppleSourceRoute {
    let decision = YlEngineRouter.assess(source)
    if let rejection = decision.rejection {
      return .reject(category: rejection.category, code: rejection.code, message: rejection.message)
    }
    return decision.candidate ?? .inspect
  }
}
