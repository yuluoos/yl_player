import Foundation

/// Pure capability assessment. It performs no I/O and never claims reachability.
enum YlEngineRouter {
  static func assess(_ source: YlAppleSourceDescriptor,
                     availability: YlRoutingAvailability = .production,
                     inspection: YlSourceInspection? = nil) -> YlSourceAssessment {
    func reject(_ category: String, _ code: String) -> YlSourceAssessment {
      .init(outcome: .incompatible, candidate: nil, satisfiedRequirements: [], limitations: [],
        rejection: NativePlayerError(category: category, code: code, message: "The requested source route is unsupported."))
    }
    guard source.kind != .content else { return reject("source", "source.invalid") }
    guard let url = source.url, !source.uri.isEmpty,
      (source.kind == .file ? url.isFileURL : (["http", "https"].contains(url.scheme?.lowercased()) && url.host?.isEmpty == false)),
      url.user == nil, url.password == nil else { return reject("source", "source.invalid_uri") }
    let options = source.loadOptions ?? .init()
    let managed = source.networkPolicy == .managed
    let bounded = options.bufferStrategy == .bounded
    let hardware = options.decoderPolicy == .hardwareRequired
    let strict = managed || bounded || hardware
    let hinted = resolvedFormat(source, url: url)
    let format = inspection?.format ?? hinted
    if [YlSourceFormat.avi, .mpegTs, .mpegPs].contains(format) {
      return reject(strict ? "unsupported" : "container", strict ? "policy.unsupported" : "container.unsupported")
    }
    if format == .matroska && source.kind == .network && source.isLive {
      return reject(strict ? "unsupported" : "container", strict ? "policy.unsupported" : "container.network_mkv_live_unsupported")
    }
    let av = [YlSourceFormat.hls, .mp4, .mov].contains(format)
    if strict && (av || (managed && !availability.managedNetwork) ||
        (bounded && !availability.boundedBuffer) || (hardware && !availability.hardwareEvidence)) {
      return reject("unsupported", "policy.unsupported")
    }
    if let inspection {
      guard inspection.demuxerSupported else { return reject("container", "container.unsupported") }
      guard inspection.codecsSupported else { return reject("decoder", "decoder.unsupported") }
      if hardware && inspection.hasVideo && inspection.hardwareAccelerated != true {
        return reject("decoder", "decoder.unavailable")
      }
    }
    var requirements: [YlRequirement] = [managed ? .networkManaged : .networkPlatformDefault]
    switch options.bufferStrategy {
    case .automatic: requirements.append(.bufferAutomatic)
    case .lowLatency: requirements.append(.bufferLowLatency)
    case .smoothPlayback: requirements.append(.bufferSmoothPlayback)
    case .bounded: requirements.append(.bufferBounded)
    }
    switch options.decoderPolicy {
    case .systemDefault: requirements.append(.decoderSystemDefault)
    case .hardwarePreferred: requirements.append(.decoderHardwarePreferred)
    case .hardwareRequired:
      if let inspection, !inspection.hasVideo || inspection.hardwareAccelerated == true {
        requirements.append(.decoderHardwareRequired)
      }
    }
    var limitations: [YlLimitation] = bounded ? [.bufferOsMemoryExcluded] : []
    if av {
      if source.hasHeaders && !(format == .hls && source.kind == .network) {
        return reject("container", "container.headers_require_fallback")
      }
      limitations.append(.decoderModeUnknown)
      if source.kind == .network { limitations.append(.networkSystemStackOpaque) }
      return .init(outcome: source.hasHeaders ? .requiresInspection : .compatible,
        candidate: source.hasHeaders ? .headeredHls : .avPlayer,
        satisfiedRequirements: requirements, limitations: limitations, rejection: nil)
    }
    if format == .automatic {
      // No engine can be committed until bounded owned inspection resolves format.
      return .init(outcome: .requiresInspection, candidate: .inspect,
        satisfiedRequirements: [], limitations: [.sourceRequiresInspection], rejection: nil)
    }
    if format == .webm && !availability.inspectedWebM ||
       format == .flv && source.kind == .file && !availability.inspectedLocalFlv {
      return reject(strict ? "unsupported" : "container", strict ? "policy.unsupported" : "container.unsupported")
    }
    if inspection == nil { limitations.append(.codecRequiresInspection) }
    let route: YlAppleSourceRoute = format == .flv ? .networkFlv : (source.kind == .file ? .localMatroska : .networkMatroska)
    return .init(outcome: inspection == nil ? .requiresInspection : .compatible, candidate: route,
      satisfiedRequirements: requirements, limitations: limitations, rejection: nil)
  }

  static func resolvedFormat(_ source: YlAppleSourceDescriptor, url: URL) -> YlSourceFormat {
    if source.formatHint != .automatic { return source.formatHint }
    switch url.pathExtension.lowercased() {
    case "m3u8", "m3u": return .hls
    case "mp4", "m4v", "m4a": return .mp4
    case "mov": return .mov
    case "mkv", "mka": return .matroska
    case "webm": return .webm
    case "flv": return .flv
    case "avi": return .avi
    case "ts", "m2ts": return .mpegTs
    case "mpg", "mpeg", "ps": return .mpegPs
    default: return .automatic
    }
  }
}
