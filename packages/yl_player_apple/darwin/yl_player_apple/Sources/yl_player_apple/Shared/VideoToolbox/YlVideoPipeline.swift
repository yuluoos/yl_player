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
  enum Resource {
    case ordinary(YlVideoToolboxDecoder, CMVideoFormatDescription)
    case fel(YlFELVideoDecoder, YlFELConfiguration)

    fileprivate var format: CMVideoFormatDescription {
      switch self {
      case let .ordinary(_, format): return format
      case let .fel(_, configuration): return configuration.baseFormat
      }
    }
    fileprivate var felConfiguration: YlFELConfiguration? {
      if case let .fel(_, configuration) = self { return configuration }
      return nil
    }
    fileprivate var decoder: YlVideoToolboxDecoder? {
      if case let .ordinary(decoder, _) = self { return decoder }
      return nil
    }
    fileprivate var felDecoder: YlFELVideoDecoder? {
      if case let .fel(decoder, _) = self { return decoder }
      return nil
    }
    func dispose() {
      switch self {
      case let .ordinary(decoder, _): decoder.dispose()
      case let .fel(decoder, _): decoder.dispose()
      }
    }
  }
  private var format: CMVideoFormatDescription
  private var felConfiguration: YlFELConfiguration?
  private var resource: Resource?
  private var decoder: YlVideoToolboxDecoder? { resource?.decoder }
  private let submissions = YlVideoSubmissionQueue()
  private let outputRelay = YlFallbackOutputRelay()
  private let bufferBudget: YlFallbackBufferBudget
  private let factory: YlVTSessionFactory
  private let policy: YlDecoderPolicy

  init(format: CMVideoFormatDescription, bufferBudget: YlFallbackBufferBudget,
       factory: YlVTSessionFactory, policy: YlDecoderPolicy = .systemDefault,
       felConfiguration: YlFELConfiguration? = nil) {
    self.policy = policy
    self.format = format
    self.bufferBudget = bufferBudget
    self.factory = factory
    self.felConfiguration = felConfiguration
  }

  private func makeFormatDescription(context: YLFMediaContextRef, streamIndex: Int32) throws -> CMVideoFormatDescription {
    try YlVideoToolboxDecoder.makeFormatDescription(context: context, streamIndex: streamIndex)
  }

  private func makeDecoder(format: CMVideoFormatDescription) throws -> YlVideoToolboxDecoder {
    let created: YlVideoToolboxDecoder
    do { created = try YlVideoToolboxDecoder(formatDescription: format,
      maxInFlightBytes: bufferBudget.inFlightPacketBytes, bufferScope: bufferBudget.bufferScope, factory: factory,
      onFrame: { [outputRelay] frame in outputRelay.frame(frame) },
      onError: { [outputRelay] error in outputRelay.error(error) })
    } catch let error as NativePlayerError {
      if policy == .hardwareRequired && (error.code == "decoder.video_hardware_unavailable" || error.code == "resource.video_decoder_limit") {
        throw YlHardwareDecoderEvidence.unavailable()
      }
      throw error
    }
    if policy == .hardwareRequired && created.hardwareEvidence.mode != .hardware {
      created.dispose()
      throw YlHardwareDecoderEvidence.unavailable()
    }
    return created
  }

  var geometry: YlVideoGeometry? { YlVideoGeometryResolver.managed(format: format) }
  var isDrained: Bool { submissions.isDrained }
  var hasDecoder: Bool { resource != nil }
  var hardwareEvidence: YlHardwareDecoderEvidence {
    resource?.felDecoder?.hardwareEvidence ?? decoder?.hardwareEvidence ?? .unknown
  }
  var usesHardwareDecoder: Bool? { resource?.felDecoder?.usesHardwareDecoder ?? decoder?.usesHardwareDecoder }
  func connect(_ output: any YlVideoPipelineOutput) { outputRelay.backend = output }
  func initializeDecoder() throws {
    let candidate = try prepareCurrent()
    install(candidate)?.dispose()
  }
  func discardDecoder() { detach()?.dispose() }
  private func makeResource(format: CMVideoFormatDescription,
                            felConfiguration: YlFELConfiguration?) throws -> Resource {
    if let felConfiguration {
      return .fel(try YlFELVideoDecoder(configuration: felConfiguration,
        bufferBudget: bufferBudget, factory: factory, policy: policy,
        onFrame: { [outputRelay] frame in outputRelay.frame(frame) },
        onError: { [outputRelay] error in outputRelay.error(error) }), felConfiguration)
    }
    return .ordinary(try makeDecoder(format: format), format)
  }
  func prepareCurrent() throws -> Resource {
    try makeResource(format: format, felConfiguration: felConfiguration)
  }
  func prepare(context: YLFMediaContextRef, streamIndex: Int32,
               checkCancellation: () throws -> Void = {},
               rewind: () throws -> Void = {
                 throw NativePlayerError(category: "unsupported", code: "decoder.fel_probe_requires_rewind",
                   message: "Dolby Vision enhancement-layer probing requires a rewindable source.")
               }) throws -> Resource {
    let candidateFEL = try YlFELConfiguration.probe(context: context, streamIndex: streamIndex,
      maxPacketBytes: bufferBudget.inFlightPacketBytes, checkCancellation: checkCancellation,
      reserveBytes: { [bufferBudget] bytes in
        guard let scope = bufferBudget.bufferScope else { return nil }
        guard let token = scope.reserve(category: .compressedPackets, bytes: bytes) else {
          throw YlManagedBufferLedger.unsupported()
        }
        return token
      }, rewind: rewind)
    let candidateFormat = try candidateFEL?.baseFormat
      ?? makeFormatDescription(context: context, streamIndex: streamIndex)
    return try makeResource(format: candidateFormat, felConfiguration: candidateFEL)
  }
  func detach() -> Resource? {
    let old = resource
    resource = nil
    return old
  }
  @discardableResult
  func install(_ candidate: Resource?) -> Resource? {
    let old = resource
    if let candidate {
      format = candidate.format
      felConfiguration = candidate.felConfiguration
    }
    resource = candidate
    return old
  }
  func finishInput(generation packetGeneration: UInt64, managedPayload: YlManagedBufferLedger.Token? = nil, hasAudio: Bool,
                   compatibility: YlAppleCompatibility) {
    if let felDecoder = resource?.felDecoder {
      // EOS validation waits for both VT sessions and all composition callbacks.
      // Keep the drain in the tracked queue so completion cannot race it.
      submissions.submit { [weak self, felDecoder] in
        guard let self, let owner = self.outputRelay.backend,
              owner.isVideoDrainCurrent(generation: packetGeneration) else { return }
        felDecoder.drain(generation: packetGeneration)
      }
      return
    }
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
      guard let activeResource = resource else {
        ylf_packet_release(&packet)
        // A main-thread live-edge transition can retire the decoder while an
        // old demux packet is arriving. Its generation fence owns cancellation.
        if shouldCancel() { onCancelled(); return nil }
        outputRelay.backend?.setDemuxPumping(false)
        outputRelay.error(NativePlayerError(
          category: "internal",
          code: "internal.fallback_invariant",
          message: "The video decoder became unavailable."
        ))
        return nil
      }
      do {
        if let felDecoder = activeResource.felDecoder {
          guard try felDecoder.consume(packet: &packet, ownedPacket: ownedPacket,
            generation: packetGeneration, managedPayload: managedPayload,
            shouldCancel: shouldCancel) else {
            onCancelled()
            return nil
          }
          onSubmitted()
          return ()
        }
        guard let decoder = activeResource.decoder else {
          throw NativePlayerError(category: "internal", code: "internal.fallback_invariant",
            message: "The selected video decoder resource was invalid.")
        }
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
          diagnostic: YlAppleSafeDiagnostics.diagnostic(error)
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
            diagnostic: YlAppleSafeDiagnostics.diagnostic(error)
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

  deinit { resource?.dispose() }

  func cancelVideoSubmissions() {
    submissions.cancelPending()
    submissions.waitUntilIdle()
  }

}
