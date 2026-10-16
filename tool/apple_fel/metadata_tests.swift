import Foundation

@main struct MetadataTests {
  static func main() throws {
    var failures = [String]()
    var checks = 0
    func rejects(_ name: String, _ key: String, _ value: Any) {
      checks += 1
      var input = metadataFixture(); input[key] = value
      do { _ = try YlFELMetadata(dictionary: input); failures.append(name + ": accepted malformed input") }
      catch {}
    }
    _ = try YlFELMetadata(dictionary: metadataFixture())
    rejects("boolean schema", "schemaVersion", true)
    rejects("rounded pivot count", "numPivots", [2.00000001, 2, 2])
    rejects("rounded mapping method", "methods", [0.00000000001] + Array(repeating: 0.0, count: 23))
    rejects("boolean coefficient", "nonlinearOffset", [true, false, false])
    rejects("missing display values", "displayMetadata", [["level": 1]])
    rejects("missing PQ", "displayMetadata", [["level": 1, "values": ["minPQ": 0, "maxPQ": 4095]]])
    rejects("PQ overflow", "displayMetadata", [["level": 1, "values": ["minPQ": 0, "maxPQ": 4096, "avgPQ": 10]]])
    rejects("fractional PQ", "displayMetadata", [["level": 1, "values": ["minPQ": 0, "maxPQ": 100, "avgPQ": 10.5]]])
    rejects("active area overflow", "displayMetadata", [["level": 5, "values": ["left": 8192, "right": 0, "top": 0, "bottom": 0]]])
    rejects("static luminance overflow", "displayMetadata", [["level": 6, "values": ["maxLuminance": 65536, "minLuminance": 0, "maxCLL": 0, "maxFALL": 0]]])
    rejects("duplicate singleton", "displayMetadata", Array(repeating: ["level": 5, "values": ["left": 0, "right": 0, "top": 0, "bottom": 0]], count: 2))
    rejects("extension block budget", "displayMetadata", Array(repeating: ["level": 5, "values": ["left": 0, "right": 0, "top": 0, "bottom": 0]], count: 33))
    rejects("negative NLQ maximum", "nlqVdrInMax", [-1, 1, 1])
    rejects("nonfinite coefficient", "polynomial", Array(repeating: Double.nan, count: 72))
    rejects("offset just above range", "nlqOffset", [1.00000000001, 0, 0])
    rejects("pivot just above range", "pivots", [0, 1.00000000001] + Array(repeating: 0.0, count: 25))
    func classify(_ name: String, _ key: String, _ value: Any, unsupported: Bool) {
      checks += 1
      var input = metadataFixture(); input[key] = value
      do { _ = try YlFELMetadata(dictionary: input); failures.append(name + ": accepted") }
      catch let error as YlFELMetadata.Failure {
        switch error {
        case .unsupported: if !unsupported { failures.append(name + ": corrupted data reported unsupported") }
        case .invalid: if unsupported { failures.append(name + ": capability reported corrupted") }
        }
      } catch { failures.append(name + ": unexpected error") }
    }
    classify("future schema", "schemaVersion", 2, unsupported: true)
    classify("other bit depth", "blBitDepth", 12, unsupported: true)
    classify("other output depth", "outputBitDepth", 8, unsupported: true)
    classify("other EOTF", "signalEOTF", 0, unsupported: true)
    classify("other color space", "signalColorSpace", 1, unsupported: true)
    classify("other full range signal", "signalFullRange", 2, unsupported: true)
    classify("large partition count", "numXPartitions", 65535, unsupported: true)
    classify("spatial filter", "spatialResamplingFilter", 1, unsupported: true)
    classify("explicit chroma", "chromaResamplingExplicitFilter", true, unsupported: true)
    classify("unknown CM", "displayMetadata", [["level": 254, "values": ["dmMode": 0, "dmVersionIndex": 2]]], unsupported: true)
    classify("creative trim", "displayMetadata", [["level": 8, "values": [:]]], unsupported: true)
    classify("unknown level", "displayMetadata", [["level": 200, "values": [:]]], unsupported: true)
    classify("nonunit NLQ", "nlqVdrInMax", [0.99999999999, 1, 1], unsupported: true)
    classify("nonunit NLQ above one", "nlqVdrInMax", [2, 1, 1], unsupported: true)
    classify("negative NLQ", "nlqVdrInMax", [-1, 1, 1], unsupported: false)
    classify("boolean flag overflow", "residualEnabled", 2, unsupported: false)
    classify("fractional method", "methods", [0.5] + Array(repeating: 0.0, count: 23), unsupported: false)
    var supported = metadataFixture()
    supported["displayMetadata"] = [
      ["level": 1, "values": ["minPQ": 0, "maxPQ": 4095, "avgPQ": 2048]],
      ["level": 5, "values": ["left": 8191, "right": 0, "top": 0, "bottom": 0]],
      ["level": 6, "values": ["maxLuminance": 65535, "minLuminance": 0, "maxCLL": 0, "maxFALL": 0]]]
    let parsed = try YlFELMetadata(dictionary: supported)
    checks += 1
    if parsed.packed.count != 709 || parsed.packed[0] != 1 || parsed.packed[4] != 0 || parsed.packed[5] != 1 {
      failures.append("schema v1 shader ABI changed")
    }
    if !failures.isEmpty {
      for failure in failures { print("FAIL " + failure) }
      exit(1)
    }
    print("FEL metadata: \(checks) admission checks passed")
  }
}
