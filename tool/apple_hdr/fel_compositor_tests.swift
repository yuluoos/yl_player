import Foundation
import CoreVideo
import Metal
import AVFoundation

func fixture() -> [String: Any] {
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
func eotf(_ p: Double) -> Double {
    let v=pow(max(p,0),1/78.84375)
    return pow(max(v-0.8359375,0)/(18.8515625-18.6875*v),1/0.1593017578125)
}
func buffer(codes: [Int], size: Int = 4) throws -> CVPixelBuffer {
    var b: CVPixelBuffer?
    assert(CVPixelBufferCreate(nil,size,size,kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,[kCVPixelBufferMetalCompatibilityKey:true,kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&b)==kCVReturnSuccess)
    let p=b!; CVPixelBufferLockBaseAddress(p,[]); defer { CVPixelBufferUnlockBaseAddress(p,[]) }
    for plane in 0..<2 {
        let base=CVPixelBufferGetBaseAddressOfPlane(p,plane)!, stride=CVPixelBufferGetBytesPerRowOfPlane(p,plane)
        for y in 0..<CVPixelBufferGetHeightOfPlane(p,plane) {
            let row=base.advanced(by:y*stride).assumingMemoryBound(to:UInt16.self)
            for x in 0..<size { row[x]=UInt16(codes[plane==0 ? 0 : 1+x%2]<<6) }
        }
    }
    return p
}
func check(_ b:CVPixelBuffer,expected:[Double], pixel:Int = 0) throws {
    CVPixelBufferLockBaseAddress(b,.readOnly); defer { CVPixelBufferUnlockBaseAddress(b,.readOnly) }
    let p=CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to:UInt16.self)
    for c in 0..<3 { let actual=Double(Float16(bitPattern:p[pixel*4+c])); assert(abs(actual-expected[c])<max(0.003,abs(expected[c])*0.003), "GPU \(actual) != CPU \(expected[c])") }
}
@main struct Tests {
    static func main() throws {
        _ = try YlFELMetadata(dictionary: fixture())
        var malformed = fixture(); malformed["polynomial"] = [Double](repeating: .nan, count: 72)
        do { _ = try YlFELMetadata(dictionary: malformed); fatalError("Malformed coefficients accepted") } catch {}
        var badPivot = fixture(); badPivot["numPivots"] = [1,2,2]
        do { _ = try YlFELMetadata(dictionary:badPivot); fatalError("Invalid pivot count accepted") } catch {}
        var badSignal = fixture(); badSignal["signalColorSpace"] = 1
        do { _ = try YlFELMetadata(dictionary:badSignal); fatalError("Unsupported signal accepted") } catch {}
        var creative = fixture(); creative["displayMetadata"] = [["level": 8, "values": [:]]]
        do { _ = try YlFELMetadata(dictionary: creative); fatalError("Creative trims silently ignored") } catch {}
        let compositor = try YlFELCompositor()
        // Finite metadata can still generate a nonfinite PQ inverse or exceed
        // the output half-float range. Metal must preserve the runtime guards.
        for (key,coefficient) in [("yccToRGB",3.0),("yccToRGB",1e38),("rgbToLMS",1e38)] {
            var overflow = fixture(); overflow[key] = [Double](repeating:coefficient,count:9)
            do {
                _ = try compositor.compose(base:buffer(codes:[600,600,600]), enhancement:buffer(codes:[512,512,512]), metadata:YlFELMetadata(dictionary:overflow))
                fatalError("Nonfinite or unrepresentable GPU output accepted for \(key)=\(coefficient)")
            } catch YlFELCompositor.Failure.unsupported(_) {
                // The GPU explicitly rejected the output before publication.
            }
        }
        let base = try buffer(codes: [600,600,600])
        for code in [512,620,410] {
            let m = try YlFELMetadata(dictionary: fixture())
            let out = try compositor.compose(base: base, enhancement: buffer(codes: [code,code,code]), metadata: m)
            let residual = code == 512 ? 0 : (code > 512 ? 1.0 : -1.0) * (abs(Double(code-512))/1023*0.2+0.001)
            let pq = Double(600)/1023+residual
            let expected = eotf(pq)*100
            try check(out, expected: [expected*1.00000021,expected*0.99998261,expected*1.00015420])
            if code == 620 { assert(expected > 1, "HDR highlight must exceed SDR white") }
        }
        // A half-resolution EL horizontal ramp. Left layer siting means BL x=0
        // samples EL x=0 exactly, BL x=1 interpolates halfway, then reaches x=1.
        var halfMetadata = fixture(); halfMetadata["elSpatialResamplingFilter"] = 1
        let halfEL = try buffer(codes:[512,512,512],size:2)
        CVPixelBufferLockBaseAddress(halfEL,[])
        for row in 0..<2 {
            CVPixelBufferGetBaseAddressOfPlane(halfEL,0)!.advanced(by:row*CVPixelBufferGetBytesPerRowOfPlane(halfEL,0)).assumingMemoryBound(to:UInt16.self)[1]=UInt16(620<<6)
        }
        CVPixelBufferUnlockBaseAddress(halfEL,[])
        let halfOut = try compositor.compose(base:base, enhancement:halfEL, metadata:YlFELMetadata(dictionary:halfMetadata))
        for (pixel,code) in [512.0,566,620,620].enumerated() {
            let r = code == 512 ? 0 : (code-512)/1023*0.2+0.001
            let x=eotf(Double(600)/1023+r), y=eotf(Double(600)/1023)
            try check(halfOut,expected:[(3.06441879*x+(-2.16597676+0.10155818)*y)*100,(-0.65612108*x+(1.78554118-0.12943749)*y)*100,(0.01736321*x+(-0.04725154+1.03004253)*y)*100],pixel:pixel)
        }
        var mmr = fixture()
        var methods = [Int](repeating: 0,count:24); methods[0]=1; mmr["methods"]=methods
        var orders = [Int](repeating:0,count:24); orders[0]=2; mmr["mmrOrder"]=orders
        var coefficients = [Double](repeating:0,count:504); coefficients[0]=0.8; coefficients[7]=0.2; mmr["mmr"]=coefficients
        let s = Double(600)/1023
        let x = eotf(0.8*s+0.2*s*s), y=eotf(s)
        let out = try compositor.compose(base:base, enhancement:buffer(codes:[512,512,512]), metadata:YlFELMetadata(dictionary:mmr))
        try check(out,expected:[(3.06441879*x+(-2.16597676+0.10155818)*y)*100,(-0.65612108*x+(1.78554118-0.12943749)*y)*100,(0.01736321*x+(-0.04725154+1.03004253)*y)*100])
        var format: CMVideoFormatDescription?
        assert(CMVideoFormatDescriptionCreateForImageBuffer(allocator:nil,imageBuffer:out,formatDescriptionOut:&format)==noErr)
        var timing=CMSampleTimingInfo(duration:CMTime(value:1,timescale:24),presentationTimeStamp:.zero,decodeTimeStamp:.invalid)
        var sample: CMSampleBuffer?
        assert(CMSampleBufferCreateReadyWithImageBuffer(allocator:nil,imageBuffer:out,formatDescription:format!,sampleTiming:&timing,sampleBufferOut:&sample)==noErr)
        let layer=AVSampleBufferDisplayLayer(); layer.enqueue(sample!)
        RunLoop.current.run(until:Date(timeIntervalSinceNow:0.2))
        assert(layer.status != .failed, "Native layer rejected RGBAHalf: \(String(describing:layer.error))")
        print("FEL metadata, signed/zero residual, MMR, HDR half-float GPU/CPU comparison and native layer enqueue passed")
    }
}
