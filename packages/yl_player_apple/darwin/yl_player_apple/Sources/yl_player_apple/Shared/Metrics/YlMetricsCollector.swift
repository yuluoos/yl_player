import Foundation

final class YlMetricsCollector {
  private let scope: YlManagedBufferScope
  private let bounded: Bool
  init(scope: YlManagedBufferScope, bounded: Bool) { self.scope = scope; self.bounded = bounded }
  var managedBufferedBytes: Int? { bounded ? scope.ledger.snapshot.currentBytes : nil }
  var managedBufferedDurationMs: Int64? {
    bounded ? scope.bufferedDurationUs / 1000 : nil
  }
}
