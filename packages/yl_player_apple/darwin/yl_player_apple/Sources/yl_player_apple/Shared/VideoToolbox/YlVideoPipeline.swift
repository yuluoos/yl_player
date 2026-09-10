import ObjectiveC
import CoreMedia
import Foundation
import YlFFmpegBridge

protocol YlVideoPipelineOutput: AnyObject {
  func setDemuxPumping(_ value: Bool)
  func receive(_ frame: YlVideoFrame)
  func fail(_ error: NativePlayerError)
  func shouldCancelVideoTask(generation: UInt64) -> Bool
  func shouldReportVideoFailure(generation: UInt64) -> Bool
  func isVideoDrainCurrent(generation: UInt64) -> Bool
}

final class YlFallbackOutputRelay {
  weak var backend: (any YlVideoPipelineOutput)?
  func frame(_ frame: YlVideoFrame) { backend?.receive(frame) }
  func error(_ error: NativePlayerError) { backend?.fail(error) }
}

private var ylManagedSamplePayloadAssociation: UInt8 = 0

/// Keep opaque ownership out of CM attachments serialized to the VT service.
/// The backing block also owns the receipt if a sample copy outlives its source.
func ylRetainManagedPayload(_ token: YlManagedBufferLedger.Token, in sample: CMSampleBuffer) {
  objc_setAssociatedObject(sample, &ylManagedSamplePayloadAssociation, token, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
  if let block = CMSampleBufferGetDataBuffer(sample) {
    objc_setAssociatedObject(block, &ylManagedSamplePayloadAssociation, token, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
  }
}

/// Owns format, decoder and serialized submissions. Session-generation predicates
/// are captured per submission and never rebound to later session authority.
final class YlVideoPipeline {
  struct Resource {
    fileprivate let decoder: YlVideoToolboxDecoder
    fileprivate let format: CMVideoFormatDescription
    func dispose() { decoder.dispose() }
  }
  private var format: CMVideoFormatDescription
  private var decoder: YlVideoToolboxDecoder?
  private let submissions = YlVideoSubmissionQueue()
  private let outputRelay = YlFallbackOutputRelay()
  private let bufferBudget: YlFallbackBufferBudget
  private let factory: YlVTSessionFactory

  init(format: CMVideoFormatDescription, bufferBudget: YlFallbackBufferBudget,
       factory: YlVTSessionFactory) {
    self.format = format
    self.bufferBudget = bufferBudget
    self.factory = factory
  }

  private func makeFormatDescription(context: YLFMediaContextRef, streamIndex: Int32) throws -> CMVideoFormatDescription {
    try YlVideoToolboxDecoder.makeFormatDescription(context: context, streamIndex: streamIndex)
  }

  private func makeDecoder(format: CMVideoFormatDescription) throws -> YlVideoToolboxDecoder {
    try YlVideoToolboxDecoder(formatDescription: format,
      maxInFlightBytes: bufferBudget.inFlightPacketBytes, bufferScope: bufferBudget.bufferScope, factory: factory,
      onFrame: { [outputRelay] frame in outputRelay.frame(frame) },
      onError: { [outputRelay] error in outputRelay.error(error) })
  }

  var isDrained: Bool { submissions.isDrained }
  var hasDecoder: Bool { decoder != nil }
  var usesHardwareDecoder: Bool? { decoder?.usesHardwareDecoder }
  func connect(_ output: any YlVideoPipelineOutput) { outputRelay.backend = output }
  func initializeDecoder() throws { decoder = try makeDecoder(format: format) }
  func discardDecoder() { decoder?.dispose(); decoder = nil }
  func prepareCurrent() throws -> Resource {
    Resource(decoder: try makeDecoder(format: format), format: format)
  }
  func prepare(context: YLFMediaContextRef, streamIndex: Int32) throws -> Resource {
    let candidateFormat = try makeFormatDescription(context: context, streamIndex: streamIndex)
    return Resource(decoder: try makeDecoder(format: candidateFormat), format: candidateFormat)
  }
  func detach() -> Resource? {
    let old = decoder.map { value in Resource(decoder: value, format: format) }
    decoder = nil
    return old
  }
  @discardableResult
  func install(_ candidate: Resource?) -> Resource? {
    let old = decoder.map { value in Resource(decoder: value, format: format) }
    if let candidate { format = candidate.format }
    decoder = candidate?.decoder
    return old
  }
  func finishInput(generation packetGeneration: UInt64, managedPayload: YlManagedBufferLedger.Token? = nil, hasAudio: Bool,
                   compatibility: YlAppleCompatibility) {
    if !compatibility.limitsVideoReservations {
      decoder?.flush()
    } else if !hasAudio {
      decoder?.drain()
    } else if let drainingDecoder = decoder {
      scheduleVideoDrain(decoder: drainingDecoder, generation: packetGeneration)
    }
  }

  func consume(packet: inout YLFPacketRef?, ownedPacket: YLFPacketRef,
                         generation packetGeneration: UInt64, managedPayload: YlManagedBufferLedger.Token? = nil, hasAudio: Bool,
                         compatibility: YlAppleCompatibility, shouldCancel: @escaping () -> Bool,
                         onSubmitted: () -> Void, onCancelled: () -> Void) -> Void? {
      guard let decoder = decoder else {
        ylf_packet_release(&packet)
        outputRelay.backend?.setDemuxPumping(false)
        outputRelay.error(NativePlayerError(
          category: "internal",
          code: "internal.fallback_invariant",
          message: "The video decoder became unavailable."
        ))
        return nil
      }
      do {
        guard try submit(packet: &packet, ownedPacket: ownedPacket, decoder: decoder,
          generation: packetGeneration, managedPayload: managedPayload, hasAudio: hasAudio,
          compatibility: compatibility, shouldCancel: shouldCancel,
          onSubmitted: onSubmitted,
          onCancelled: onCancelled,
          schedule: scheduleVideoDecode) != nil else { return nil }
      } catch let error as NativePlayerError {
        ylf_packet_release(&packet)
        outputRelay.backend?.setDemuxPumping(false)
        outputRelay.error(error)
        return nil
      } catch {
        ylf_packet_release(&packet)
        outputRelay.backend?.setDemuxPumping(false)
        outputRelay.error(NativePlayerError(
          category: "internal",
          code: "internal.fallback_invariant",
          message: "The video decoder buffer reservation failed.",
          diagnostic: String(describing: error)
        ))
        return nil
      }
    return ()
  }

  /// Nil preserves the cancelled-reservation early return: the caller must not
  /// schedule another demux turn. A non-nil Void means this packet turn completed.
  func submit(packet: inout YLFPacketRef?, ownedPacket: YLFPacketRef,
              decoder: YlVideoToolboxDecoder, generation packetGeneration: UInt64,
              managedPayload: YlManagedBufferLedger.Token? = nil, hasAudio: Bool, compatibility: YlAppleCompatibility,
              shouldCancel: @escaping () -> Bool,
              onSubmitted: () -> Void, onCancelled: () -> Void,
              schedule: (CMSampleBuffer, UInt64, YlVideoToolboxDecoder, YlVideoDecodeReservation) -> Void) throws -> Void? {
        let byteCount = ylf_packet_size(ownedPacket)
        let managedPayload = managedPayload ?? bufferBudget.bufferScope?.reserve(category: .compressedPackets, bytes: byteCount)
        guard bufferBudget.bufferScope == nil || managedPayload != nil else { throw YlManagedBufferLedger.unsupported() }
        // Charge the sample before either the sample buffer or queue can own it.
        let reservation: YlVideoDecodeReservation?
        if compatibility.limitsVideoReservations || bufferBudget.bufferScope != nil {
          reservation = try !hasAudio
            ? decoder.reserve(byteCount: byteCount, shouldCancel: shouldCancel)
            : decoder.reserveSubmission(byteCount: byteCount, shouldCancel: shouldCancel)
        } else { reservation = nil }
        guard !compatibility.limitsVideoReservations || reservation != nil else {
          ylf_packet_release(&packet)
          onCancelled()
          return nil
        }
        reservation?.managedPayload = managedPayload
        var unmanagedSample: Unmanaged<CMSampleBuffer>?
        let sampleResult = ylf_create_video_sample_buffer(
          &packet,
          format,
          &unmanagedSample
        )
        if sampleResult == 0, let unmanagedSample {
          onSubmitted()
          let sample = unmanagedSample.takeRetainedValue()
          // Bridge CMBlockBuffer takes the AVPacket without a copy. Transfer the
          // same token and bind it to actual sample lifetime, including any
          // delayed decoder retention beyond the output callback.
          if let managedPayload {
            ylRetainManagedPayload(managedPayload, in: sample)
          }
          if !compatibility.limitsVideoReservations || !hasAudio {
            decoder.decode(
              sample: sample, generation: packetGeneration, reservation: reservation
            )
          } else {
            schedule(sample, packetGeneration, decoder, reservation!)
          }
        } else {
          ylf_packet_release(&packet)
        }
    return ()
  }

  func scheduleVideoDecode(
    _ sample: CMSampleBuffer,
    generation packetGeneration: UInt64,
    decoder: YlVideoToolboxDecoder,
    reservation: YlVideoDecodeReservation
  ) {
    submissions.submit { [weak self, decoder] in
      guard let self, let owner = self.outputRelay.backend else { return }
      do {
        guard try reservation.beginDecoding(shouldCancel: {
          owner.shouldCancelVideoTask(generation: packetGeneration)
        }) else { return }
        decoder.decode(sample: sample, generation: packetGeneration, reservation: reservation)
      } catch let error as NativePlayerError {
        if owner.shouldReportVideoFailure(generation: packetGeneration) { self.outputRelay.error(error) }
      } catch {
        if owner.shouldReportVideoFailure(generation: packetGeneration) {
          self.outputRelay.error(NativePlayerError(
            category: "internal", code: "internal.fallback_invariant",
            message: "The video decoder buffer reservation failed.",
            diagnostic: String(describing: error)
          ))
        }
      }
    }
  }

  func scheduleVideoDrain(
    decoder: YlVideoToolboxDecoder,
    generation packetGeneration: UInt64
  ) {
    submissions.submit { [weak self, decoder] in
      guard let self, let owner = self.outputRelay.backend,
            owner.isVideoDrainCurrent(generation: packetGeneration) else { return }
      decoder.drain()
    }
  }

  func cancelVideoSubmissions() {
    submissions.cancelPending()
    submissions.waitUntilIdle()
  }

}
