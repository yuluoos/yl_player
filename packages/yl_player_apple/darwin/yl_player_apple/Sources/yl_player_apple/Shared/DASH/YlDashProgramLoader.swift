import Foundation

/// Preflight uses the same request authority as every later segment. Alternative
/// SegmentBase indexes are fetched as one intent, never as independent retries.
enum YlDashProgramLoader {
  struct Inspection {
    let manifest: YlDashProgramResources.Payload
    let indexes: [YlDashIndexRequest: YlDashResolvedIndex]
    func program(source: URL) throws -> YlDashProgram {
      try YlDashProgramLoader.translatingErrors {
        try YlDashProgramDocument.parse(manifest.data, source: source, final: manifest.finalURL,
          credentialsStripped: manifest.credentialsStripped, indexes: indexes)
      }
    }
  }
  static func load(url: URL, resources: YlDashProgramResources,
                   cancellation: YlOpenCancellationToken) throws -> YlDashProgram {
    try inspect(url: url, resources: resources, cancellation: cancellation).program(source: url)
  }
  /// The same bounded root/index bytes can select the established HLS projection
  /// or the precise programme path without a second MPD request or retry budget.
  static func inspect(url: URL, resources: YlDashProgramResources,
                      cancellation: YlOpenCancellationToken) throws -> Inspection {
    try translatingErrors {
      let manifest = try resources.read(.init(candidates: [.init(url: url, credentialsStripped: false)], range: nil),
        maximumBytes: 2 * 1024 * 1024, cancellation: cancellation)
      var indexes: [YlDashIndexRequest: YlDashResolvedIndex] = [:]
      for resource in try YlDashProgramDocument.indexResources(manifest.data, source: url,
        final: manifest.finalURL, credentialsStripped: manifest.credentialsStripped) {
        let range = resource.range!
        let bytes = try resources.read(resource, maximumBytes: Int(range.length), cancellation: cancellation)
        guard let length = bytes.resourceLength else { throw YlDashSidxError.invalidIndex }
        let index = try YlDashSidx.parse(bytes.data, boxEndOffset: UInt64(range.start) + UInt64(range.length), maxReferences: YlDashBounds.maxSegments)
        let resolved = YlDashResolvedIndex(index: index, effectiveURL: bytes.finalURL,
          credentialsStripped: bytes.credentialsStripped, resourceLength: length)
        for candidate in resource.candidates {
          indexes[.init(url: candidate.url, start: range.start, length: Int(range.length),
            credentialsStripped: candidate.credentialsStripped)] = resolved
        }
      }
      try cancellation.throwIfCancelled()
      return Inspection(manifest: manifest, indexes: indexes)
    }
  }
  private static func translatingErrors<T>(_ operation: () throws -> T) throws -> T {
    do { return try operation() }
    catch let error as NativePlayerError { throw error }
    catch let error as YlDashAdmissionError { throw error.nativeError }
    catch let error as YlDashSidxError { throw error.nativeError }
    catch {
      throw NativePlayerError(category: "container", code: "container.dash_manifest_invalid",
        message: "The DASH programme does not provide a valid bounded timeline.")
    }
  }
}
