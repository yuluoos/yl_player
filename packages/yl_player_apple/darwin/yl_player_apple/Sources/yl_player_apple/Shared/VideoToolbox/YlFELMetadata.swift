import CoreFoundation
import Foundation

/// Immutable bridge schema v1. NLQ slope includes EL code range; threshold
/// includes the half-code correction (libplacebo pl_map_dovi_metadata equations).
/// Admission proves the bridge contract only, not complete display mapping.
struct YlFELMetadata {
    enum Failure: Error, LocalizedError {
        case invalid(String)
        case unsupported(String)
        var errorDescription: String? {
            switch self {
            case .invalid(let reason): return "Invalid FEL metadata: \(reason)"
            case .unsupported(let reason): return "Unsupported FEL metadata: \(reason)"
            }
        }
    }
    let packed: [Float]
    let blFullRange: Bool
    let elSpatialResamplingFilter: Int
    let displayMetadata: [[String: Any]]
    private let activeArea: (left: Int, right: Int, top: Int, bottom: Int)?

    func validateFrame(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw Failure.invalid("frame dimensions") }
        if let area = activeArea {
            guard area.left + area.right < width, area.top + area.bottom < height else {
                throw Failure.invalid("empty active area")
            }
        }
    }

    init(dictionary d: [String: Any]) throws {
        func number(_ value: Any?, _ key: String) throws -> NSNumber {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite else { throw Failure.invalid(key) }
            return n
        }
        func integer(_ key: String, in values: [String: Any]? = nil,
                     range: ClosedRange<Int>) throws -> Int {
            let value = try number((values ?? d)[key], key).doubleValue
            guard value.rounded() == value, value >= Double(range.lowerBound),
                  value <= Double(range.upperBound) else { throw Failure.invalid(key) }
            return Int(value)
        }
        func flag(_ key: String) throws -> Bool {
            // Objective-C BOOLs can bridge as CFBoolean or numeric 0/1.
            guard let n = d[key] as? NSNumber, n.doubleValue == 0 || n.doubleValue == 1 else {
                throw Failure.invalid(key)
            }
            return n.boolValue
        }
        func array(_ key: String, _ count: Int, integers: Bool = false, range: ClosedRange<Double>? = nil) throws -> [Float] {
            guard let values = d[key] as? [Any], values.count == count else { throw Failure.invalid(key) }
            return try values.map {
                let n = try number($0, key)
                guard n.floatValue.isFinite, range?.contains(n.doubleValue) ?? true,
                      !integers || (n.doubleValue.rounded() == n.doubleValue &&
                        Double(n.floatValue) == n.doubleValue) else { throw Failure.invalid(key) }
                return n.floatValue
            }
        }
        // Unknown schema layouts cannot safely be interpreted using schema v1.
        guard try integer("schemaVersion", range: 1...Int(Int32.max)) == 1 else {
            throw Failure.unsupported("schema version")
        }
        let blDepth = try integer("blBitDepth", range: 8...16)
        let elDepth = try integer("elBitDepth", range: 8...16)
        let outputDepth = try integer("outputBitDepth", range: 8...16)
        let eotf = try integer("signalEOTF", range: 0...65535)
        let colorSpace = try integer("signalColorSpace", range: 0...3)
        let signalDepth = try integer("signalBitDepth", range: 8...16)
        let signalFull = try integer("signalFullRange", range: 0...3)
        let xPartitions = try integer("numXPartitions", range: 1...65535)
        let yPartitions = try integer("numYPartitions", range: 1...65535)
        let spatialFilter = try integer("spatialResamplingFilter", range: 0...1)
        let elFilter = try integer("elSpatialResamplingFilter", range: 0...1)
        let explicit = try flag("chromaResamplingExplicitFilter")
        let full = try flag("blFullRange"), residual = try flag("residualEnabled")
        guard let levels = d["displayMetadata"] as? [[String: Any]], levels.count <= 32 else {
            throw Failure.invalid("display metadata block count")
        }
        var activeArea: (left: Int, right: Int, top: Int, bottom: Int)?
        var unsupportedLevel = false
        var seen = Set<Int>()
        for entry in levels {
            let level = try integer("level", in: entry, range: 1...255)
            guard let values = entry["values"] as? [String: Any] else {
                throw Failure.invalid("display metadata values")
            }
            let keys: [String], range: ClosedRange<Int>
            switch level {
            case 1: keys = ["minPQ", "maxPQ", "avgPQ"]; range = 0...4095
            case 5: keys = ["left", "right", "top", "bottom"]; range = 0...8191
            case 6: keys = ["maxLuminance", "minLuminance", "maxCLL", "maxFALL"]; range = 0...65535
            default:
                // Includes CM4's L254 and creative trims. Presence is never ignored.
                unsupportedLevel = true
                continue
            }
            guard seen.insert(level).inserted else { throw Failure.invalid("duplicate display metadata") }
            let parsed = try keys.map { try integer($0, in: values, range: range) }
            if level == 5 { activeArea = (parsed[0], parsed[1], parsed[2], parsed[3]) }
        }
        let counts = try array("numPivots", 3, integers: true), pivots = try array("pivots", 27, range: 0...1)
        let methods = try array("methods", 24, integers: true), poly = try array("polynomial", 72)
        let orders = try array("mmrOrder", 24, integers: true), constants = try array("mmrConstant", 24)
        let mmr = try array("mmr", 504)
        for c in 0..<3 {
            guard (2...9).contains(counts[c]) else { throw Failure.invalid("pivot count") }
            let n = Int(counts[c])
            for i in 0..<n {
                let p = pivots[c*9+i]
                guard (0...1).contains(p), i == 0 || p > pivots[c*9+i-1] else { throw Failure.invalid("pivot order") }
            }
            for i in 0..<(n-1) {
                let k = c*8+i
                guard methods[k] == 0 || methods[k] == 1 else { throw Failure.invalid("mapping method") }
                if methods[k] == 1 {
                    guard [Float(1),2,3].contains(orders[k]) else { throw Failure.invalid("MMR order") }
                }
            }
        }
        let offsets = try array("nlqOffset", 3, range: 0...1), slopes = try array("nlqSlope", 3, range: 0...Double.greatestFiniteMagnitude)
        let thresholds = try array("nlqThreshold", 3), maxima = try array("nlqVdrInMax", 3, range: 0...Double.greatestFiniteMagnitude)
        let nonlinear = try array("nonlinearOffset", 3), ycc = try array("yccToRGB", 9)
        let lms = try array("rgbToLMS", 9)
        guard offsets.allSatisfy({ (0...1).contains($0) }), slopes.allSatisfy({ $0 >= 0 }),
              maxima.allSatisfy({ $0 >= 0 }) else { throw Failure.invalid("NLQ range") }
        // Validate known syntax before classifying a supported schema's capability.
        guard blDepth == 10, elDepth == 10, outputDepth >= 10 else { throw Failure.unsupported("bit depth") }
        guard eotf == 65535, colorSpace == 0, signalDepth == 12, signalFull == 1,
              xPartitions == 1, yPartitions == 1 else { throw Failure.unsupported("signal encoding or partitions") }
        guard spatialFilter == 0, !explicit else { throw Failure.unsupported("resampling filter") }
        guard !unsupportedLevel else { throw Failure.unsupported("display metadata or CM; creative trims are not executed") }
        guard (d["nlqVdrInMax"] as? [NSNumber])?.allSatisfy({ $0.doubleValue == 1 }) == true else { throw Failure.unsupported("NLQ maximum") }
        blFullRange = full
        displayMetadata = levels
        self.activeArea = activeArea
        elSpatialResamplingFilter = elFilter
        var p: [Float] = [residual ? 1 : 0]
        p += counts; p += pivots; p += methods; p += poly; p += orders; p += constants; p += mmr
        p += nonlinear; p += ycc; p += lms
        p += offsets; p += slopes; p += thresholds
        packed = p
    }
}
