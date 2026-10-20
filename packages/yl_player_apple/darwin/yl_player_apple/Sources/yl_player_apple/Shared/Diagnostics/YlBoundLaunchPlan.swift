#if DEBUG && YL_BOUND_AV
import Foundation
import Darwin

/// One-shot input for an explicitly opted-in acceptance build. It lives outside
/// the frozen app bundle; the observer still validates its entire product manifest.
/// CoreDevice/Flutter's debug launcher replaces custom environment variables.
enum YlBoundLaunchPlan {
  private static let limit = 1024 * 1024
  static func consume(environment: [String: String], directory: URL) throws -> String? {
    if let encoded = environment["YL_P03_BOUND_PLAN"] {
      guard !encoded.isEmpty, encoded.utf8.count <= limit else { throw invalid() }
      return encoded
    }
    let file = directory.appendingPathComponent("p03-bound-plan.txt")
    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      throw invalid()
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var attributes = stat()
    guard fstat(descriptor, &attributes) == 0,
      attributes.st_mode & S_IFMT == S_IFREG else { throw invalid() }
    // Even invalid ordinary plans must not be replayed on a later launch.
    try FileManager.default.removeItem(at: file)
    guard attributes.st_size > 0, attributes.st_size <= limit,
      let bytes = try handle.read(upToCount: limit + 1), !bytes.isEmpty,
      bytes.count <= limit, let encoded = String(data: bytes, encoding: .utf8)
    else { throw invalid() }
    return encoded
  }
  private static func invalid() -> NSError { NSError(domain: "P03BoundPlan", code: 1) }
}
#endif
