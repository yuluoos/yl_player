import Foundation
import YlFFmpegBridge

/// Immutable codec metadata survives demux replacement without retaining its I/O.
final class YlSoftwareVideoConfiguration {
  private enum ConfigurationError: Error { case invalid }

  let handle: YLFSoftwareVideoConfigurationRef
  let descriptor: YLFSoftwareVideoDescriptor

  init(context: YLFMediaContextRef, streamIndex: Int32) throws {
    var copy: YLFSoftwareVideoConfigurationRef?
    guard ylf_software_video_copy_configuration(context, streamIndex, &copy) == YLFResultOK,
          let copy else { throw ConfigurationError.invalid }
    var value = YLFSoftwareVideoDescriptor()
    guard ylf_software_video_copy_descriptor(
      copy, MemoryLayout<YLFSoftwareVideoDescriptor>.size, &value) == YLFResultOK else {
      ylf_software_video_free_configuration(copy)
      throw ConfigurationError.invalid
    }
    handle = copy
    descriptor = value
  }

  deinit { ylf_software_video_free_configuration(handle) }
}
