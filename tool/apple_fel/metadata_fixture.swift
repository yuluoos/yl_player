import Foundation

func metadataFixture() -> [String: Any] {
    var p = [Double](repeating: 0, count: 27)
    var poly = [Double](repeating: 0, count: 72)
    for c in 0..<3 { p[c*9+1] = 1; poly[c*24+1] = 1 }
    return ["signalEOTF": 65535, "signalColorSpace": 0, "signalBitDepth": 12, "signalFullRange": 1, "numXPartitions": 1, "numYPartitions": 1, "schemaVersion": 1, "blBitDepth": 10, "elBitDepth": 10, "outputBitDepth": 12,
            "blFullRange": false, "residualEnabled": true, "numPivots": [2,2,2], "pivots": p,
            "methods": [Int](repeating: 0, count: 24), "polynomial": poly,
            "mmrOrder": [Int](repeating: 0, count: 24), "mmrConstant": [Double](repeating: 0, count: 24),
            "mmr": [Double](repeating: 0, count: 504), "nonlinearOffset": [0.0,0,0],
            "yccToRGB": [1.0,0,0,0,1,0,0,0,1], "rgbToLMS": [1.0,0,0,0,1,0,0,0,1],
            "nlqOffset": [512.0/1023,512.0/1023,512.0/1023], "nlqSlope": [0.2,0.2,0.2],
            "nlqThreshold": [0.001,0.001,0.001], "nlqVdrInMax": [1.0,1,1],
            "spatialResamplingFilter": 0, "elSpatialResamplingFilter": 0,
            "chromaResamplingExplicitFilter": false, "displayMetadata": []]
}

