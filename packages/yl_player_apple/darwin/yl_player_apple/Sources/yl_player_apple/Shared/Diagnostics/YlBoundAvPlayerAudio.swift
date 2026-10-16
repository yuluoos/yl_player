#if DEBUG && YL_BOUND_AV
import AVFoundation
import MediaToolbox

/// Opt-in observation of the actual AVPlayer item's pre-effects source pull.
/// A tap consumes decoded PCM to fill the audio queue; it does NOT expose the
/// hardware playback head. Its range must never be labelled played samples.
/// Only owned local, clear, single-audio-track fixtures are observed. No reader,
/// alternate decoder, replacement output, or playback clock is introduced.
final class YlBoundAvPlayerAudio {
  struct Block { let pts: Int64; let end: Int64; let rate: Double; let samples: [[Float]] }
  private weak var player: AVPlayer?
  private weak var item: AVPlayerItem?
  private var state: Storage?
  private var retired = [Storage]()
  private(set) var epoch = -1
  private(set) var failure: String?
  private var targetUs: Int64 = 0
  init(player: AVPlayer, item: AVPlayerItem) {
    self.player = player; self.item = item
    install()
  }

  /// Each public seek installs a distinct tap before the player seeks. Late
  /// callbacks own only retired storage and cannot enter the new phase.
  func install(targetUs: Int64 = 0) {
    self.targetUs = targetUs
    guard let item, let asset = item.asset as? AVURLAsset, asset.url.isFileURL else {
      failure = "tap requires an owned local asset"; return
    }
    if let state { retired.append(state) }
    item.audioMix = nil
    epoch += 1
    let tracks = asset.tracks(withMediaType: .audio)
    guard tracks.count == 1 else { failure = "tap requires exactly one audio track"; return }
    let next = Storage()
    var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0,
      clientInfo: Unmanaged.passUnretained(next).toOpaque(),
      init: { _, info, storage in
        guard let info else { return }
        storage.pointee = Unmanaged.passRetained(Unmanaged<Storage>.fromOpaque(info).takeUnretainedValue()).toOpaque()
      },
      finalize: { tap in
        let value = Unmanaged<Storage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeRetainedValue()
        OSAtomicIncrement32Barrier(value.finalizedFlag)
      },
      prepare: { tap, _, format in
        let value = Unmanaged<Storage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        value.format = format.pointee
      }, unprepare: nil,
      process: { tap, requested, _, buffers, frames, flags in
        var range = CMTimeRange.invalid
        let status = MTAudioProcessingTapGetSourceAudio(tap, requested, buffers, flags, &range, frames)
        let value = Unmanaged<Storage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        value.record(status: status, buffers: buffers, frames: frames.pointee, range: range)
      })
    var tap: MTAudioProcessingTap?
    let result = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
      kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
    guard result == noErr, let tap else { failure = "tap create \(result)"; return }
    let parameters = AVMutableAudioMixInputParameters(track: tracks[0])
    parameters.audioTapProcessor = tap
    let mix = AVMutableAudioMix(); mix.inputParameters = [parameters]
    state = next; item.audioMix = mix
  }

  /// Drop the item's reference. Finalization is observed, not inferred from nil.
  func detach() { item?.audioMix = nil }
  var released: Bool { ([state].compactMap { $0 } + retired).allSatisfy { storage in storage.finalized } }
  var evidence: [Block] { state?.blocks ?? [] }
  var diagnostic: String { "epoch=\(epoch) error=\(failure ?? "none") blocks=\(state?.count ?? 0) dropped=\(state?.drops ?? 0) released=\(released) detail=\(state?.detail ?? "none")" }
  var ready: Bool {
    guard let player, let item, player.currentItem === item, let range = state?.lastRange else { return false }
    return range.0 >= targetUs && failure == nil
  }

  /// Read only a paused player's last actual pull. This is a queue-fill range,
  /// deliberately not AVPlayer.currentTime or a host-time extrapolation.
  var pausedPull: [String: Any]? {
    guard player?.rate == 0 else { return nil }
    return currentPull
  }

  /// Snapshot a real queue request while audio keeps running. Pausing AVPlayer
  /// repeatedly reprimes its source and would create holes in PCM observation.
  var currentPull: [String: Any]? {
    guard ready, let range = state?.lastRange else { return nil }
    return ["tapEpoch": epoch, "pullStartUs": range.0, "pullEndUs": range.1,
      "pullFrames": range.2, "pullRate": range.3]
  }

  /// Fixed capacity; the render callback copies samples without allocation or
  /// waiting for the reporting thread. The serial tap producer publishes immutable
  /// slots with a memory barrier; reporting never blocks or drops a callback.
  /// Overflow/invalid timed PCM invalidates evidence.
  private final class Storage {
    struct Entry { var pts: Int64 = 0; var end: Int64 = 0; var offset = 0; var frames = 0; var channels = 0; var rate: Double = 0 }
    var format = AudioStreamBasicDescription()
    let finalizedFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    var finalized: Bool { OSAtomicAdd32Barrier(0, finalizedFlag) != 0 }
    private let capacity = 1_536_000
    private let samples = UnsafeMutablePointer<Float>.allocate(capacity: 1_536_000)
    private let entries = UnsafeMutablePointer<Entry>.allocate(capacity: 4096)
    private let dropped = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private var used = 0, entryCount = 0
    private let published = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let untimed = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    var detail: String { "unmapped=\(OSAtomicAdd32Barrier(0, untimed))" }
    init() { published.initialize(to: 0); untimed.initialize(to: 0); finalizedFlag.initialize(to: 0); dropped.initialize(to: 0); entries.initialize(repeating: Entry(), count: 4096) }
    deinit { published.deinitialize(count: 1); published.deallocate(); untimed.deinitialize(count: 1); untimed.deallocate(); finalizedFlag.deinitialize(count: 1); finalizedFlag.deallocate(); samples.deallocate(); entries.deinitialize(count: 4096); entries.deallocate(); dropped.deinitialize(count: 1); dropped.deallocate() }
    var drops: Int32 { OSAtomicAdd32Barrier(0, dropped) }
    var count: Int { Int(OSAtomicAdd32Barrier(0, published)) }
    func record(status: OSStatus, buffers: UnsafeMutablePointer<AudioBufferList>, frames: Int, range: CMTimeRange) {
      if frames == 0 && status == noErr { return }
      // AVPlayer can pull zero-duration silence while priming/draining. It has
      // no media time and cannot advance the observed queue-fill range.
      if status == noErr && (!range.start.isNumeric || !range.duration.isNumeric || range.duration.value == 0) {
        OSAtomicIncrement32Barrier(untimed); return
      }
      let channels = Int(format.mChannelsPerFrame), rate = format.mSampleRate
      guard status == noErr, frames > 0, frames <= 65_536, (1...2).contains(channels),
        rate.isFinite, (8_000...192_000).contains(rate), format.mFormatID == kAudioFormatLinearPCM,
        format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32,
        format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
        range.start.isNumeric, range.duration.isNumeric,
        entryCount < 4096, frames * channels <= capacity - used else {
        OSAtomicIncrement32Barrier(dropped); return
      }
      let start = CMTimeConvertScale(range.start, timescale: 1_000_000, method: .roundTowardZero).value
      let end = CMTimeConvertScale(CMTimeRangeGetEnd(range), timescale: 1_000_000, method: .roundTowardZero).value
      guard end > start else { OSAtomicIncrement32Barrier(dropped); return }
      let list = UnsafeMutableAudioBufferListPointer(buffers)
      let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
      guard list.count == (planar ? channels : 1), list.allSatisfy({
        $0.mData != nil && Int($0.mDataByteSize) >= frames * (planar ? 1 : channels) * 4
      }) else { OSAtomicIncrement32Barrier(dropped); return }
      // Preserve the API source range and actual PCM count independently.
      // Neither field is a played-sample head.
      for channel in 0..<channels {
        let input = list[planar ? channel : 0].mData!.assumingMemoryBound(to: Float.self)
        for frame in 0..<frames { samples[used + frame * channels + channel] = input[planar ? frame : frame * channels + channel] }
      }
      entries[entryCount] = Entry(pts: start, end: end, offset: used, frames: frames, channels: channels, rate: rate)
      used += frames * channels; entryCount += 1
      OSAtomicIncrement32Barrier(published) // Publish immutable PCM/metadata after the copy.
    }
    var lastRange: (Int64, Int64, Int, Double)? {
      let available = count
      guard drops == 0, available > 0 else { return nil }
      let e = entries[available - 1]; return (e.pts, e.end, e.frames, e.rate)
    }
    var blocks: [Block] {
      let available = count
      guard drops == 0 else { return [] }
      return (0..<available).map { index in
        let e = entries[index]
        return Block(pts: e.pts, end: e.end, rate: e.rate, samples: (0..<e.channels).map { channel in
          (0..<e.frames).map { samples[e.offset + $0 * e.channels + channel] }
        })
      }
    }
  }
}
#endif
