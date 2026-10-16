import AVFoundation
let dir="/private/tmp/yl-p03-pcm-20261015/"
for method in [AVAudioConverterPrimeMethod.none, .normal, .pre] {
 for zero in [false,true] {
  var desc=AudioStreamBasicDescription(mSampleRate:48000,mFormatID:kAudioFormatEnhancedAC3,mFormatFlags:0,mBytesPerPacket:0,mFramesPerPacket:0,mBytesPerFrame:0,mChannelsPerFrame:2,mBitsPerChannel:0,mReserved:0)
  let input=AVAudioFormat(streamDescription:&desc)!, output=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:48000,channels:2,interleaved:false)!
  let c=AVAudioConverter(from:input,to:output)!
  c.primeMethod=method
  if zero {c.primeInfo = .init(leadingFrames:0,trailingFrames:0)}
  print("config",method.rawValue,zero,"prime",c.primeInfo.leadingFrames,c.primeInfo.trailingFrames)
  let data=try Data(contentsOf:URL(fileURLWithPath:dir+"eac3.packets"));var offset=0;var samples=[Float]();var lengths=[Int]()
  while offset<data.count {
   let size=data.withUnsafeBytes {Int($0.loadUnaligned(fromByteOffset:offset,as:UInt32.self))};offset+=4
   let compressed=AVAudioCompressedBuffer(format:input,packetCapacity:1,maximumPacketSize:size)
   data.withUnsafeBytes {memcpy(compressed.data,$0.baseAddress!.advanced(by:offset),size)};offset+=size
   compressed.packetDescriptions!.pointee = .init(mStartOffset:0,mVariableFramesInPacket:0,mDataByteSize:UInt32(size));compressed.byteLength=UInt32(size);compressed.packetCount=1
   let pcm=AVAudioPCMBuffer(pcmFormat:output,frameCapacity:3072)!;var sent=false;var error:NSError?
   let status=c.convert(to:pcm,error:&error) {_,s in if sent {s.pointee = .noDataNow;return nil};sent=true;s.pointee = .haveData;return compressed}
   if status == .error {print(error!);break}
   lengths.append(Int(pcm.frameLength))
   for f in 0..<Int(pcm.frameLength) {samples += [pcm.floatChannelData![0][f],pcm.floatChannelData![1][f]]}
  }
  print("frames",samples.count/2,"head",lengths.prefix(4),"tail",lengths.suffix(4),"prime",c.primeInfo.leadingFrames,c.primeInfo.trailingFrames)
  let pcm=AVAudioPCMBuffer(pcmFormat:output,frameCapacity:3072)!;var error:NSError?
  let status=c.convert(to:pcm,error:&error) {_,s in s.pointee = .endOfStream;return nil}
  print("drain",status.rawValue,pcm.frameLength,error as Any)
  for f in 0..<Int(pcm.frameLength) {samples += [pcm.floatChannelData![0][f],pcm.floatChannelData![1][f]]}
  try samples.withUnsafeBytes {try Data($0).write(to:URL(fileURLWithPath:dir+"prime-\(method.rawValue)-\(zero).f32"))}
 }
}
