import Foundation

enum YlMacosLifecycleEvent {
  case didResignActive
  case didBecomeActive
  case willTerminate
}

enum YlMacosLifecycleAction: Equatable {
  case preserve
  case emitState
  case disposeAll
}

enum YlMacosLifecyclePolicy {
  static func action(for event: YlMacosLifecycleEvent) -> YlMacosLifecycleAction {
    switch event {
    case .didResignActive:
      return .preserve
    case .didBecomeActive:
      return .emitState
    case .willTerminate:
      return .disposeAll
    }
  }
}
