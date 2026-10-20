import yl_player_media_core
import Foundation
import YlFFmpegBridge

enum YlFELFailure {
  static func make(_ code: String = "decoder.dolby_vision_fel_invalid", _ detail: String) -> NativePlayerError {
    NativePlayerError(category: code == "resource.network_buffer_limit" ? "resource" : "decoderFailure", code: code,
      message: "The complete Dolby Vision enhancement layer could not be rendered.", diagnostic: detail)
  }
  static func bridge(_ status: Int32, _ operation: String) -> NativePlayerError {
    if status == YLFResultDolbyVisionUnsupported {
      return NativePlayerError(category: "unsupported", code: "decoder.dolby_vision_fel_metadata_unsupported",
        message: "Complete rendering of this Dolby Vision enhancement metadata is unsupported.",
        diagnostic: "FEL \(operation) result \(status)")
    }
    return make("decoder.dolby_vision_fel_invalid", "FEL \(operation) result \(status)")
  }
  static func metadata(_ dictionary: [String: Any], frameSize: (width: Int, height: Int)? = nil) throws -> YlFELMetadata {
    do {
      let metadata = try YlFELMetadata(dictionary: dictionary)
      if let size = frameSize { try metadata.validateFrame(width: size.width, height: size.height) }
      return metadata
    }
    catch YlFELMetadata.Failure.unsupported(let detail) {
      throw NativePlayerError(category: "unsupported", code: "decoder.dolby_vision_fel_metadata_unsupported",
        message: "Complete rendering of this Dolby Vision enhancement metadata is unsupported.",
        diagnostic: detail)
    } catch {
      throw make("decoder.dolby_vision_fel_invalid", "Malformed FEL bridge metadata")
    }
  }
}

