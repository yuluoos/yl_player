import Foundation

/// Compressed input only. No player, output surface or generated wire records.
public struct YlMediaDeliveryInput {
  public let recipe: YlFallbackSourceRecipe
  public let isLive: Bool
  public init(recipe: YlFallbackSourceRecipe, isLive: Bool) {
    self.recipe = recipe
    self.isLive = isLive
  }
}

/// The consumer retains this object for as long as the receiver needs its URL.
public final class YlDeliveredMedia {
  public let url: URL
  private let cleanup: () -> Void
  private let failureSubscription: ((@escaping (NativePlayerError) -> Void) -> Void)?
  public init(url: URL, cleanup: @escaping () -> Void,
              observeFailure: ((@escaping (NativePlayerError) -> Void) -> Void)? = nil) {
    self.url = url
    self.cleanup = cleanup
    failureSubscription = observeFailure
  }
  public func observeFailure(_ handler: @escaping (NativePlayerError) -> Void) {
    failureSubscription?(handler)
  }
  deinit { cleanup() }
}

/// Each caller owns its own session; no messenger or player is shared.
public protocol YlMediaDeliverySession: AnyObject {
  var onState: ((String, String, NativePlayerError?) -> Void)? { get set }
  func validate(input: YlMediaDeliveryInput) throws
  func prepare(id: String, input: YlMediaDeliveryInput,
               reply: @escaping (Result<URL, Error>) -> Void)
  func release(id: String)
  func close()
}

public protocol YlMediaDeliveryService: AnyObject {
  func prepare(input: YlMediaDeliveryInput, token: YlOpenCancellationToken) throws -> YlDeliveredMedia
  func makeSession() -> any YlMediaDeliverySession
}

/// Registry entries are scoped to Flutter's engine messenger identity.
/// Services are stateless factories. Registration order is resolved at use time.
public enum YlMediaDeliveryRegistry {
  private static let lock = NSLock()
  private static var services: [ObjectIdentifier: any YlMediaDeliveryService] = [:]
  public static func install(_ service: any YlMediaDeliveryService, for engine: ObjectIdentifier) {
    lock.lock(); defer { lock.unlock() }
    services[engine] = service
  }
  public static func remove(for engine: ObjectIdentifier) {
    lock.lock(); defer { lock.unlock() }
    services.removeValue(forKey: engine)
  }
  public static func service(for engine: ObjectIdentifier) throws -> any YlMediaDeliveryService {
    lock.lock(); defer { lock.unlock() }
    guard let service = services[engine] else { throw unavailable() }
    return service
  }
  public static func unavailable() -> NativePlayerError {
    NativePlayerError(category: "unsupported", code: "airplay.delivery_unavailable",
      message: "Add yl_player_media_delivery to enable custom media delivery.")
  }
}
