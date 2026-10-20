import yl_player_media_core
@testable import yl_player_media_delivery
import Foundation

final class FixtureBytes: YlByteSource {
  let data: Data
  let chunk: Int
  var offset = 0
  init(_ data: Data, chunk: Int) { self.data = data; self.chunk = chunk }
  var length: Int64? { nil }
  var currentOffset: Int64 { Int64(offset) }
  var supportsRandomAccess: Bool { false }
  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    let count = min(chunk, min(buffer.count, data.count - offset))
    data.copyBytes(to: buffer.bindMemory(to: UInt8.self), from: offset..<(offset + count))
    offset += count; return count
  }
  func seek(to offset: Int64) throws -> Int64 { fatalError("Unexpected seek") }
  func cancel() {}
  func handleMemoryWarning() {}
}
@main struct ValidatorTests {
  static func main() throws {
    let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    func validate(_ data: Data, chunk: Int) throws {
      let source = YlAirPlayFLVValidator(source: FixtureBytes(data, chunk: chunk))
      let start = try source.seek(to: 0)
      precondition(start == 0)
      var buffer = [UInt8](repeating: 0, count: 32768)
      while try buffer.withUnsafeMutableBytes({ try source.read(into: $0) }) != 0 {}
      let end = source.currentOffset
      let unchanged = try source.seek(to: end)
      precondition(unchanged == end)
      do { _ = try source.seek(to: 0); fatalError("Sequential validator accepted rewind") }
      catch let YlByteSourceError.failed(error) { precondition(error.code == "source.not_seekable") }
    }
    for chunk in [1, 7, 1024, 32768] { try validate(input, chunk: chunk) }
    for video in [false, true] {
      var changed = input
      var offset = 13
      while offset + 15 < changed.count {
        let size = changed[(offset + 1)..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        if changed[offset] == (video ? 9 : 8), changed[offset + 12] == 0 {
          if video {
            // Both avcC and SPS move from level1.2 to level1.3.
            changed[offset + 19] = 13; changed[offset + 27] = 13
          } else {
            // AAC-LC ASC: 48kHz mono ->44.1kHz mono.
            changed[offset + 13] = 0x12; changed[offset + 14] = 0x08
          }
          break
        }
        offset += size + 15
      }
      let stream = input + changed.dropFirst(13)
      do { try validate(stream, chunk: 7); fatalError("Changed sequence header was accepted") }
      catch let YlByteSourceError.failed(error) { precondition(error.code == "airplay.unsupported_codec") }
      print("PASS \(video ? "H.264" : "AAC") sequence header change rejected before demux")
    }
    var oversized = input.prefix(13)
    oversized.append(contentsOf: [9, 0x80, 0, 1, 0, 0, 0, 0, 0, 0, 0])
    do { try validate(oversized, chunk: 1); fatalError("Oversized tag accepted") }
    catch let YlByteSourceError.failed(error) { precondition(error.code == "airplay.resource_limit") }
    print("PASS byte-fragmented FLV headers/media, early8MiB tag bound")
  }
}
