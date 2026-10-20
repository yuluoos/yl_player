import yl_player_media_core
import Foundation

/// An immutable-file live origin. Opening and retiring resources share the same
/// lock: an accepted HTTP reader owns its descriptor until its lease closes.
final class YlAirPlayLiveStore {
  private struct Segment {
    let name: String
    let duration: Double
    let period: Int
    let sequence: Int
    let discontinuity: Int
    let startsPeriod: Bool
  }
  private struct Resource {
    let size: Int
    var published: Bool
    var retireAfter: TimeInterval?
    var readers = 0
  }
  private let directory: URL
  private let now: () -> TimeInterval
  private let lock = NSLock()
  private var resources: [String: Resource] = [:]
  private var segments: [Segment] = []
  private var period = -1
  private var sequence = 0
  private var discontinuity = 0
  private var maximumPlaylistDuration = 0.0
  private var playlistGeneration = 0
  private var playlistReaders: [Int: Int] = [:]
  private var playlistSizes: [Int: Int] = [:]
  private var ready = false
  private var finished = false
  private var terminalError: Error?
  private static let maximumBytes = 128 * 1024 * 1024
  private static let maximumFiles = 128
  // Reserve both the playlist and its atomic replacement, even during startup.
  private static let playlistReserveBytes = 64 * 1024

  init(directory: URL, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
    self.directory = directory
    self.now = now
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
      throw YlAirPlayRemux.failure("resource_limit", "Live AirPlay requires a fresh temporary directory.")
    }
  }

  var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }

  func checkError() throws {
    lock.lock(); defer { lock.unlock() }
    if let terminalError { throw terminalError }
  }

  func beginPeriod(initialization: Data) throws -> Int {
    try mutate {
      guard !initialization.isEmpty else { throw Self.invalid("The live initialization segment is empty.") }
      // A failed startup/reconnect may produce an init without any media. It was
      // never published and can be removed immediately.
      if period >= 0, !segments.contains(where: { $0.period == period }) {
        let unused = "init-\(period).mp4"
        if resources[unused]?.published == false { try remove(unused) }
      }
      let next = period + 1
      try writeImmutable(initialization, name: "init-\(next).mp4")
      period = next
      return next
    }
  }

  func append(data: Data, duration: Double, period requestedPeriod: Int) throws {
    try mutate {
      guard requestedPeriod == period, period >= 0 else { throw Self.invalid("The live segment belongs to an inactive period.") }
      guard duration.isFinite, duration > 0, duration.rounded() <= 6 else {
        throw YlAirPlayRemux.failure("unsupported_timeline", "Live AirPlay requires a keyframe span whose rounded duration is at most six seconds.")
      }
      guard !data.isEmpty else { throw Self.invalid("The live media segment is empty.") }
      let startsPeriod = segments.last?.period != period
      let nextDiscontinuity = discontinuity + ((startsPeriod && sequence > 0) ? 1 : 0)
      let segment = Segment(name: "segment-\(sequence).m4s", duration: duration,
        period: period, sequence: sequence, discontinuity: nextDiscontinuity, startsPeriod: startsPeriod && sequence > 0)
      var next = segments + [segment]
      var length = next.reduce(0) { $0 + $1.duration }
      var removed: [Segment] = []
      while let first = next.first, next.count > 1,
            length - first.duration >= 30 || (next.count > 32 && length - first.duration >= 18) {
        removed.append(next.removeFirst())
        length -= first.duration
      }
      guard next.count <= 32 else {
        throw YlAirPlayRemux.failure("resource_limit", "Live segments are too short to maintain the minimum playlist within the segment limit.")
      }
      try writeImmutable(data, name: segment.name)
      mediaPeriods[segment.name] = period
      segments = next
      sequence += 1
      discontinuity = nextDiscontinuity
      let retirementTime = now()
      for old in removed {
        // RFC 8216: keep a removed segment for its duration plus the longest
        // playlist containing it. The global maximum is conservative.
        resources[old.name]?.retireAfter = retirementTime + maximumPlaylistDuration + old.duration
      }
      maximumPlaylistDuration = max(maximumPlaylistDuration, length)
      if length >= 18 {
        try publishPlaylist()
        ready = true
      }
    }
  }

  func finish() throws {
    lock.lock(); defer { lock.unlock() }
    if let terminalError { throw terminalError }
    guard !finished else { return }
    finished = true
    if ready {
      do { try publishPlaylist() } catch { terminalError = error; throw error }
    }
  }

  func resolve(_ name: String) throws -> YlAirPlayHTTPResource? {
    lock.lock(); defer { lock.unlock() }
    try collectExpired()
    guard !name.contains("/"), !name.contains("%"), !name.contains("\\"),
          (name == "index.m3u8" && ready) || resources[name]?.published == true else { return nil }
    if resources[name]?.retireAfter.map({ $0 <= now() }) == true { return nil }
    let file = try FileHandle(forReadingFrom: directory.appendingPathComponent(name))
    do {
      let length = try file.seekToEnd()
      try file.seek(toOffset: 0)
      let generation = playlistGeneration
      if name == "index.m3u8" {
        if playlistReaders[generation] == nil {
          try checkCapacity(addingBytes: Int(length), addingFiles: 1)
          playlistSizes[generation] = Int(length)
        }
        playlistReaders[generation, default: 0] += 1
      } else { resources[name]?.readers += 1 }
      return YlAirPlayHTTPResource(file: file, length: Int(length),
        contentType: name == "index.m3u8" ? "application/vnd.apple.mpegurl" : "video/mp4",
        onClose: { self.releaseReader(name, generation: generation) })
    } catch { try? file.close(); throw error }
  }

  private func mutate<T>(_ body: () throws -> T) throws -> T {
    lock.lock(); defer { lock.unlock() }
    if let terminalError { throw terminalError }
    guard !finished else { throw Self.invalid("The live store has finished.") }
    do { try collectExpired(); return try body() }
    catch { terminalError = error; throw error }
  }

  private func writeImmutable(_ data: Data, name: String) throws {
    try checkCapacity(addingBytes: data.count, addingFiles: 1)
    try data.write(to: directory.appendingPathComponent(name), options: .withoutOverwriting)
    resources[name] = Resource(size: data.count, published: false, retireAfter: nil)
  }

  private func publishPlaylist() throws {
    guard let first = segments.first else { return }
    var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:6",
      "#EXT-X-MEDIA-SEQUENCE:\(first.sequence)",
      "#EXT-X-DISCONTINUITY-SEQUENCE:\(first.discontinuity - (first.startsPeriod ? 1 : 0))"]
    var lastPeriod: Int?
    for segment in segments {
      if segment.startsPeriod { lines.append("#EXT-X-DISCONTINUITY") }
      if lastPeriod != segment.period {
        lines.append("#EXT-X-MAP:URI=\"init-\(segment.period).mp4\"")
        lastPeriod = segment.period
      }
      lines.append(String(format: "#EXTINF:%.6f,", locale: Locale(identifier: "en_US_POSIX"), segment.duration))
      lines.append(segment.name)
    }
    if finished { lines.append("#EXT-X-ENDLIST") }
    let data = Data((lines.joined(separator: "\n") + "\n").utf8)
    guard data.count * 2 <= Self.playlistReserveBytes else {
      throw YlAirPlayRemux.failure("resource_limit", "The live playlist exceeds its reserved storage.")
    }
    try data.write(to: directory.appendingPathComponent("index.m3u8"), options: .atomic)
    playlistGeneration += 1
    for segment in segments {
      resources[segment.name]?.published = true
      resources["init-\(segment.period).mp4"]?.published = true
    }
  }

  private func collectExpired() throws {
    let time = now()
    for (name, resource) in resources where resource.retireAfter.map({ $0 <= time }) == true {
      try remove(name)
    }
    // Init resources survive as long as any active or retained media can refer
    // to them. The current init also survives before its first segment arrives.
    let referencedPeriods = Set(resources.keys.filter { $0.hasPrefix("segment-") })
    // A removed segment's period must remain known until that segment expires.
    for name in Array(resources.keys) where name.hasPrefix("init-") && name != "init-\(period).mp4" {
      if !segments.contains(where: { "init-\($0.period).mp4" == name }) && !retainedPeriodHasMedia(name, media: referencedPeriods) {
        try remove(name)
      }
    }
  }

  private var mediaPeriods: [String: Int] = [:]
  private func retainedPeriodHasMedia(_ name: String, media: Set<String>) -> Bool {
    media.contains { "init-\(mediaPeriods[$0] ?? -1).mp4" == name }
  }
  private func remove(_ name: String) throws {
    guard resources[name]?.readers == 0 else { return }
    try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    resources.removeValue(forKey: name)
    mediaPeriods.removeValue(forKey: name)
  }
  private func checkCapacity(addingBytes: Int, addingFiles: Int) throws {
    // Old atomic playlist snapshots still occupy storage while a reader holds
    // their descriptor. Count each generation once, even with several readers.
    let bytes = resources.values.reduce(0) { $0 + $1.size } + playlistSizes.values.reduce(0, +)
    guard addingBytes <= Self.maximumBytes - Self.playlistReserveBytes - bytes,
          resources.count + playlistSizes.count + addingFiles + 2 <= Self.maximumFiles else {
      throw YlAirPlayRemux.failure("resource_limit", "Live AirPlay exhausted its receiver-safe temporary storage limit.")
    }
  }

  private func releaseReader(_ name: String, generation: Int) {
    lock.lock(); defer { lock.unlock() }
    if name == "index.m3u8" {
      if let count = playlistReaders[generation], count > 1 { playlistReaders[generation] = count - 1 }
      else { playlistReaders.removeValue(forKey: generation); playlistSizes.removeValue(forKey: generation) }
    } else if let count = resources[name]?.readers, count > 0 { resources[name]?.readers = count - 1 }
    do { try collectExpired() } catch { terminalError = error }
  }

  private static func invalid(_ message: String) -> Error {
    YlAirPlayRemux.failure("remux_failed", message)
  }
}
