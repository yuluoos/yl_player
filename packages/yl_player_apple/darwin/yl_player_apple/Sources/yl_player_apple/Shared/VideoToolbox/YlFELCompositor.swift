import Foundation
import CoreVideo
import CoreGraphics
import Metal

/// Reconstructs FEL to extended linear BT.2020 (1.0 = 100 cd/m²).
/// Sampling follows the open-source reconstruction contract: left-sited 2:1
/// enhancement layer and bilinear plane reconstruction. It is not a claim of
/// normative Dolby display management; creative trims are rejected by metadata.
/// Executes synchronously on its caller's serial decode queue; never on the UI thread.
/// Equations independently expressed from libplacebo colorspace.c/libav_internal.h
/// (https://github.com/haasn/libplacebo), including LINEAR_DZ and HPE LMS conversion.
final class YlFELCompositor {
    enum Failure: Error { case unsupported(String), allocation, metal(String) }
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var cache: CVMetalTextureCache
    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw Failure.metal("No Metal device") }
        self.device = device; self.queue = queue
        let options = MTLCompileOptions()
        // Fast math permits the compiler to assume NaN/Inf cannot occur and
        // remove isfinite checks. Malformed finite coefficients can overflow
        // during reconstruction, so these checks are part of the contract.
        options.fastMathEnabled = false
        let library = try device.makeLibrary(source: Self.shader, options: options)
        guard let function = library.makeFunction(name: "composeFEL") else { throw Failure.metal("Missing kernel") }
        pipeline = try device.makeComputePipelineState(function: function)
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { throw Failure.allocation }
        self.cache = cache
    }
    func compose(base: CVPixelBuffer, enhancement: CVPixelBuffer, metadata: YlFELMetadata) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(base), height = CVPixelBufferGetHeight(base)
        let ew = CVPixelBufferGetWidth(enhancement), eh = CVPixelBufferGetHeight(enhancement)
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0, ew % 2 == 0, eh % 2 == 0,
              (ew == width && eh == height) || (ew*2 == width && eh*2 == height) else { throw Failure.unsupported("EL geometry") }
        guard (metadata.elSpatialResamplingFilter == 0 && ew == width) || (metadata.elSpatialResamplingFilter == 1 && ew*2 == width) else { throw Failure.unsupported("EL resampling geometry") }
        for buffer in [base, enhancement] {
            let format = CVPixelBufferGetPixelFormatType(buffer)
            guard [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange].contains(format), CVPixelBufferGetPlaneCount(buffer) == 2 else { throw Failure.unsupported("Expected P010") }
        }
        var result: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_64RGBAHalf, attributes as CFDictionary, &result) == kCVReturnSuccess, let output = result else { throw Failure.allocation }
        var wrappers: [CVMetalTexture] = []
        func texture(_ buffer: CVPixelBuffer, _ plane: Int, _ format: MTLPixelFormat, _ w: Int, _ h: Int) throws -> MTLTexture {
            var ref: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format, w, h, plane, &ref) == kCVReturnSuccess,
                  let ref, let texture = CVMetalTextureGetTexture(ref) else { throw Failure.allocation }
            wrappers.append(ref); return texture
        }
        let textures = try [texture(base, 0, .r16Unorm, width, height), texture(base, 1, .rg16Unorm, width/2, height/2),
                            texture(enhancement, 0, .r16Unorm, ew, eh), texture(enhancement, 1, .rg16Unorm, ew/2, eh/2),
                            texture(output, 0, .rgba16Float, width, height)]
        func chromaShift(_ buffer: CVPixelBuffer) throws -> [Float] {
            // MPEG/HEVC 4:2:0 defaults to horizontally left, vertically centered.
            guard let value = CVBufferCopyAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, nil) else { return [0.5,0] }
            let location = value as? String
            if location == kCVImageBufferChromaLocation_Left as String { return [0.5,0] }
            if location == kCVImageBufferChromaLocation_Center as String { return [0,0] }
            if location == kCVImageBufferChromaLocation_TopLeft as String { return [0.5,0.5] }
            throw Failure.unsupported("Chroma location")
        }
        var params = metadata.packed
        params += try chromaShift(base); params += try chromaShift(enhancement)
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw Failure.allocation }
        guard let numericalFailure = device.makeBuffer(length: 4, options: .storageModeShared) else { throw Failure.allocation }
        numericalFailure.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        encoder.setBuffer(numericalFailure, offset: 0, index: 1)
        encoder.setComputePipelineState(pipeline)
        for (i, texture) in textures.enumerated() { encoder.setTexture(texture, index: i) }
        params.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        withExtendedLifetime(wrappers) {}
        guard command.status == .completed else { throw Failure.metal(command.error?.localizedDescription ?? "composition failed") }
        guard numericalFailure.contents().load(as: UInt32.self) == 0 else { throw Failure.unsupported("Nonfinite or unrepresentable reconstructed color") }
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_Linear, .shouldPropagate)
        if let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) { CVBufferSetAttachment(output, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate) }
        return output
    }
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    float3 matrix3(constant float *m, float3 x) {
        return float3(dot(float3(m[0],m[1],m[2]),x), dot(float3(m[3],m[4],m[5]),x), dot(float3(m[6],m[7],m[8]),x));
    }
    float3 sampleYCC(texture2d<float,access::sample> y, texture2d<float,access::sample> uv, float2 pos, float2 shift) {
        constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
        float2 chroma = uv.sample(s,pos+shift/float2(y.get_width(),y.get_height())).rg;
        return float3(y.sample(s,pos).r,chroma)*(65535.0f/(64.0f*1023.0f));
    }
    kernel void composeFEL(texture2d<float,access::sample> by [[texture(0)]], texture2d<float,access::sample> bc [[texture(1)]],
                           texture2d<float,access::sample> ey [[texture(2)]], texture2d<float,access::sample> ec [[texture(3)]],
                           texture2d<half,access::write> out [[texture(4)]], constant float *p [[buffer(0)]], device atomic_uint *failure [[buffer(1)]], uint2 id [[thread_position_in_grid]]) {
        if(id.x>=out.get_width()||id.y>=out.get_height()) return;
        float2 pos=(float2(id)+0.5f)/float2(out.get_width(),out.get_height());
        float3 sig=clamp(sampleYCC(by,bc,pos,float2(p[709],p[710])),0.0f,1.0f), reshaped;
        for(int c=0;c<3;c++) {
            int n=int(p[1+c]), piece=0;
            for(int i=1;i<n-1;i++) if(sig[c]>=p[4+c*9+i]) piece=i;
            int k=c*8+piece;
            if(p[31+k]==0) { int a=55+k*3; reshaped[c]=p[a]+sig[c]*(p[a+1]+sig[c]*p[a+2]); }
            else {
                float terms[7]={sig.x,sig.y,sig.z,sig.x*sig.y,sig.x*sig.z,sig.y*sig.z,sig.x*sig.y*sig.z};
                float value=p[151+k];
                for(int order=0;order<int(p[127+k]);order++) for(int t=0;t<7;t++) value+=p[175+k*21+order*7+t]*pow(terms[t],float(order+1));
                reshaped[c]=value;
            }
            reshaped[c]=clamp(reshaped[c],p[4+c*9],p[4+c*9+n-1]);
        }
        float2 elPos=pos;
        if(ey.get_width()<by.get_width()) elPos.x+=0.5f/float(by.get_width());
        float3 el=sampleYCC(ey,ec,elPos,float2(p[711],p[712]));
        if(p[0]!=0) for(int c=0;c<3;c++) {
            float r=el[c]-p[700+c];
            // Exact code-zero remains zero, including float roundoff in P010 normalization.
            if(abs(r)>0.000001f) reshaped[c]+=sign(r)*(abs(r)*p[703+c]+p[706+c]);
        }
        float3 nonlinear=matrix3(p+682,reshaped-float3(p[679],p[680],p[681]));
        float3 v=pow(max(nonlinear,0.0f),float3(1.0f/78.84375f));
        float3 linear=pow(max(v-0.8359375f,0.0f)/(18.8515625f-18.6875f*v),float3(1.0f/0.1593017578125f));
        float3 lms=matrix3(p+691,linear);
        float3 rgb=float3(dot(float3(3.06441879,-2.16597676,0.10155818),lms),dot(float3(-0.65612108,1.78554118,-0.12943749),lms),dot(float3(0.01736321,-0.04725154,1.03004253),lms))*100.0f;
        if(!all(isfinite(rgb)) || any(abs(rgb)>65504.0f)) {
            atomic_store_explicit(failure,1u,memory_order_relaxed); return;
        }
        out.write(half4(half3(rgb),half(1)),id);
    }
    """
}
