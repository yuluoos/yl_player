import AVFoundation
let dir="/private/tmp/yl-p03-pcm-20261015/"
var component=AudioComponentDescription(componentType:kAudioDecoderComponentType,componentSubType:kAudioFormatEnhancedAC3,componentManufacturer:0,componentFlags:0,componentFlagsMask:0)
var codec:AudioComponentInstance?; print("new",AudioComponentInstanceNew(AudioComponentFindNext(nil,&component)!,&codec))
let c=codec!;defer { AudioComponentInstanceDispose(c) }
var n:UInt32=0;var writable:DarwinBoolean=false
print("formats info",AudioCodecGetPropertyInfo(c,kAudioCodecPropertySupportedInputFormats,&n,&writable),n)
var formats=[AudioStreamBasicDescription](repeating:AudioStreamBasicDescription(),count:Int(n)/MemoryLayout<AudioStreamBasicDescription>.stride)
print("formats",AudioCodecGetProperty(c,kAudioCodecPropertySupportedInputFormats,&n,&formats),formats)
var input=AudioStreamBasicDescription(mSampleRate:48000,mFormatID:kAudioFormatEnhancedAC3,mFormatFlags:0,mBytesPerPacket:0,mFramesPerPacket:0,mBytesPerFrame:0,mChannelsPerFrame:2,mBitsPerChannel:0,mReserved:0)
let outputFormat=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:48000,channels:2,interleaved:true)!
var output=outputFormat.streamDescription.pointee
var method:UInt32=kAudioCodecPrimeMethod_None
var prime=AudioCodecPrimeInfo(leadingFrames:0,trailingFrames:0)
print("primeInfoSet",AudioCodecSetProperty(c,kAudioCodecPropertyPrimeInfo,UInt32(MemoryLayout<AudioCodecPrimeInfo>.size),&prime))
var layout=AudioChannelLayout(mChannelLayoutTag:kAudioChannelLayoutTag_Stereo,mChannelBitmap:[],mNumberChannelDescriptions:0,mChannelDescriptions:AudioChannelDescription())
print("layout",AudioCodecSetProperty(c,kAudioCodecPropertyInputChannelLayout,UInt32(MemoryLayout<AudioChannelLayout>.size),&layout),AudioCodecSetProperty(c,kAudioCodecPropertyOutputChannelLayout,UInt32(MemoryLayout<AudioChannelLayout>.size),&layout))
print("asbd",input,output)
print("init",AudioCodecInitialize(c,&input,&output,nil,0))
print("postInitPrime",AudioCodecSetProperty(c,kAudioCodecPropertyPrimeInfo,UInt32(MemoryLayout<AudioCodecPrimeInfo>.size),&prime))
let data=try Data(contentsOf:URL(fileURLWithPath:dir+"eac3.packets"));var offset=0;var samples=[Float]();var lengths=[Int]()
while offset<data.count {
 let size=data.withUnsafeBytes {Int($0.loadUnaligned(fromByteOffset:offset,as:UInt32.self))};offset+=4
 var bytes=UInt32(size),packets:UInt32=1
 var desc=AudioStreamPacketDescription(mStartOffset:0,mVariableFramesInPacket:1536,mDataByteSize:bytes)
 let result=data.withUnsafeBytes {AudioCodecAppendInputData(c,$0.baseAddress!.advanced(by:offset),&bytes,&packets,&desc)};offset+=size
 if result != 0 {print("append",result);break}
 var pcm=[Float](repeating:0,count:3072*2);var sizeOut=UInt32(pcm.count*4);var frames:UInt32=3072;var status:UInt32=0
 let res=pcm.withUnsafeMutableBytes {AudioCodecProduceOutputPackets(c,$0.baseAddress!,&sizeOut,&frames,nil,&status)}
 if res != 0 {print("produce",res,status);break}
 lengths.append(Int(sizeOut/8));samples += pcm.prefix(Int(sizeOut/4))
}
print("frames",samples.count/2,"head",lengths.prefix(4),"tail",lengths.suffix(4))
try samples.withUnsafeBytes {try Data($0).write(to:URL(fileURLWithPath:dir+"codec.f32"))}
