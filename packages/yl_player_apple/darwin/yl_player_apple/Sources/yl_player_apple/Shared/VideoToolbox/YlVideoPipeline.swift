import CoreMedia
import Foundation
import YlFFmpegBridge

protocol YlVideoPipelineOutput: AnyObject {
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

/// Owns format, decoder and serialized submissions. Session-generation predicates
/// are captured per submission and never rebound to later session authority.
final class YlVideoPipeline {
  var format: CMVideoFormatDescription
  var decoder: YlVideoToolboxDecoder?
  let submissions = YlVideoSubmissionQueue()
  let outputRelay = YlFallbackOutputRelay()
  private let bufferBudget: YlFallbackBufferBudget
  private let factory: YlVTSessionFactory

  init(format: CMVideoFormatDescription, bufferBudget: YlFallbackBufferBudget,
       factory: YlVTSessionFactory) {
    self.format = format
    self.bufferBudget = bufferBudget
    self.factory = factory
  }

  func makeDecoder(format: CMVideoFormatDescription) throws -> YlVideoToolboxDecoder {
    try YlVideoToolboxDecoder(formatDescription: format,
      maxInFlightBytes: bufferBudget.inFlightPacketBytes, factory: factory,
      onFrame: { [outputRelay] frame in outputRelay.frame(frame) },
      onError: { [outputRelay] error in outputRelay.error(error) })
  }

  func submit(packet: inout YLFPacketRef?, ownedPacket: YLFPacketRef,
              decoder: YlVideoToolboxDecoder, generation packetGeneration: UInt64,
              hasAudio: Bool, compatibility: YlAppleCompatibility,
              shouldCancel: @escaping () -> Bool,
              onSubmitted: () -> Void, onCancelled: () -> Void,
              schedule: (CMSampleBuffer, UInt64, YlVideoToolboxDecoder, YlVideoDecodeReservation) -> Void) throws -> Void? {
        let byteCount = ylf_packet_size(ownedPacket)
        // Charge the sample before either the sample buffer or queue can own it.
        let reservation: YlVideoDecodeReservation?
        if compatibility.limitsVideoReservations {
          reservation = try !hasAudio
            ? decoder.reserve(byteCount: byteCount, shouldCancel: shouldCancel)
            : decoder.reserveSubmission(byteCount: byteCount, shouldCancel: shouldCancel)
        } else { reservation = nil }
        guard !compatibility.limitsVideoReservations || reservation != nil else {
          ylf_packet_release(&packet)
          onCancelled()
          return nil
        }
        var unmanagedSample: Unmanaged<CMSampleBuffer>?
        let sampleResult = ylf_create_video_sample_buffer(
          &packet,
          format,
          &unmanagedSample
        )
        if sampleResult == 0, let unmanagedSample {
          onSubmitted()
          let sample = unmanagedSample.takeRetainedValue()
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
