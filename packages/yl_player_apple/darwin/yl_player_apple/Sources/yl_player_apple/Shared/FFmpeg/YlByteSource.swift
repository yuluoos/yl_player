import Foundation

enum YlByteSourceError: Error {
  case cancelled
  case closed
  case invalidOffset(expected: Int64, actual: Int64)
  case failed(NativePlayerError)
}

protocol YlByteSource: AnyObject {
  var length: Int64? { get }
  var supportsRandomAccess: Bool { get }
  var currentOffset: Int64 { get }

  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int
  func seek(to offset: Int64) throws -> Int64
  func interruptRead()
  func resumeReads()
  func cancel()
  func handleMemoryWarning()
}

protocol YlMediaTimeSeekableByteSource: YlByteSource {
  var durationUs: Int64 { get }
  func seek(toMediaTimeUs positionUs: Int64) throws -> Int64
}

extension YlByteSource {
  func interruptRead() {}
  func resumeReads() {}
}
