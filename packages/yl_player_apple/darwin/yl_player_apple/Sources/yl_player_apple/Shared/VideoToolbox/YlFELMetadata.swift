import Foundation

/// Immutable bridge schema v1. NLQ slope includes EL code range; threshold
/// includes the half-code correction (libplacebo pl_map_dovi_metadata equations).
struct YlFELMetadata {
    enum Failure: Error, LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let reason) = self { return "FEL metadata: \(reason)" }; return nil }
    }
    let packed: [Float]
    let blFullRange: Bool
    let elSpatialResamplingFilter: Int
    let displayMetadata: [[String: Any]]
    init(dictionary d: [String: Any]) throws {
        func integer(_ key: String) throws -> Int {
            guard let n = d[key] as? NSNumber, n.doubleValue.isFinite, n.doubleValue == Double(n.intValue) else { throw Failure.invalid(key) }
            return n.intValue
        }
        func array(_ key: String, _ count: Int) throws -> [Float] {
            guard let a = d[key] as? [NSNumber], a.count == count else { throw Failure.invalid(key) }
            let f = a.map { $0.floatValue }; guard f.allSatisfy({ $0.isFinite }) else { throw Failure.invalid(key) }; return f
        }
        guard try integer("schemaVersion") == 1, try integer("blBitDepth") == 10, try integer("elBitDepth") == 10,
              try (10...16).contains(integer("outputBitDepth")) else { throw Failure.invalid("schema/bit depth") }
        guard try integer("signalEOTF") == 65535, try integer("signalColorSpace") == 0,
              try integer("signalBitDepth") == 12, try integer("signalFullRange") == 1,
              try integer("numXPartitions") == 1, try integer("numYPartitions") == 1 else {
            throw Failure.invalid("unsupported signal color encoding or partitions")
        }
        let elFilter = try integer("elSpatialResamplingFilter")
        guard try integer("spatialResamplingFilter") == 0, [0,1].contains(elFilter),
              let explicit = d["chromaResamplingExplicitFilter"] as? Bool, !explicit else { throw Failure.invalid("resampling filter") }
        guard let full = d["blFullRange"] as? Bool, let residual = d["residualEnabled"] as? Bool,
              let levels = d["displayMetadata"] as? [[String: Any]] else { throw Failure.invalid("flags/display metadata") }
        for entry in levels { guard let level = entry["level"] as? Int, [1,5,6].contains(level) else { throw Failure.invalid("unsupported Dolby display metadata; creative trims are not executed") } }
        blFullRange = full; displayMetadata = levels; elSpatialResamplingFilter = elFilter
        let counts = try array("numPivots", 3), pivots = try array("pivots", 27)
        let methods = try array("methods", 24), poly = try array("polynomial", 72)
        let orders = try array("mmrOrder", 24), constants = try array("mmrConstant", 24), mmr = try array("mmr", 504)
        for c in 0..<3 {
            guard (2...9).contains(counts[c]), counts[c].rounded() == counts[c] else { throw Failure.invalid("pivot count") }
            let n = Int(counts[c])
            for i in 0..<n { let p = pivots[c*9+i]; guard (0...1).contains(p), i == 0 || p > pivots[c*9+i-1] else { throw Failure.invalid("pivot order") } }
            for i in 0..<(n-1) { let k = c*8+i; guard methods[k] == 0 || methods[k] == 1 else { throw Failure.invalid("mapping method") }; if methods[k] == 1 { guard [Float(1),2,3].contains(orders[k]) else { throw Failure.invalid("MMR order") } } }
        }
        let offsets = try array("nlqOffset", 3), slopes = try array("nlqSlope", 3), thresholds = try array("nlqThreshold", 3)
        let maxima = try array("nlqVdrInMax", 3)
        guard offsets.allSatisfy({ (0...1).contains($0) }), slopes.allSatisfy({ $0 >= 0 }), maxima.allSatisfy({ $0 == 1 }) else { throw Failure.invalid("unsupported NLQ range") }
        var p: [Float] = [residual ? 1 : 0]
        p += counts; p += pivots; p += methods; p += poly; p += orders; p += constants; p += mmr
        p += try array("nonlinearOffset", 3); p += try array("yccToRGB", 9); p += try array("rgbToLMS", 9)
        p += offsets; p += slopes; p += thresholds; packed = p
    }
}
