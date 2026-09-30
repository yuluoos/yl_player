import Foundation
@main struct Test {
 static func main() throws {
  var checks=0, failures=0
  func check(_ value: Bool, _ name: String) { checks += 1; if !value { failures += 1; print("FAIL \(name)") } }
  let data=[UInt8](try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
  var offset=32, count=0, keys=0, reference:YlVP9FrameHeader?
  while offset+12<=data.count {
   let size=(0..<4).reduce(0){$0 | Int(data[offset+$1]) << ($1*8)};offset+=12
   let packet=Array(data[offset..<offset+size]);offset+=size;count+=1
   let header=packet.withUnsafeBufferPointer { YlVP9FrameHeader.parse($0,reference:reference) }
   check(header != nil,"owned packet \(count)")
   if let header { check(header.width==320 && header.height==180,"fixed geometry"); if header.keyframe{keys+=1;reference=header} }
  }
  check(count==96 && keys==4,"96 frames and 4 keyframes")
  let key:[UInt8]=[0x82,0x49,0x83,0x42,0x00,0x13,0xf0,0x0b,0x36,0x06,0x38,0x24]
  for length in 0..<9 {check(Array(key.prefix(length)).withUnsafeBufferPointer{YlVP9FrameHeader.parse($0)}==nil,"truncated header \(length)")}
  for first:UInt8 in [0x02,0x92,0x8a,0x80] { var bad=key;bad[0]=first;check(bad.withUnsafeBufferPointer{YlVP9FrameHeader.parse($0)}==nil,"unsupported marker/profile/show-existing/hidden") }
  var bad=key;bad[2]=0;check(bad.withUnsafeBufferPointer{YlVP9FrameHeader.parse($0)}==nil,"bad sync")
  let superframe=key+[0xc1,UInt8(key.count),0,0xc1];check(superframe.withUnsafeBufferPointer{YlVP9FrameHeader.parse($0)}==nil,"superframe rejected")
  let opening = key.withUnsafeBufferPointer { YlVP9FrameHeader.parse($0) }!
  var gate = YlVP9PacketGate(opening: opening)
  check(key.withUnsafeBufferPointer { gate.accepts($0) }, "initial keyframe")
  for change: UInt8 in [0x10, 0x20, 0x40] {
    var changed = key; changed[4] = change // range, BT601, BT709; dimensions unchanged
    check(!changed.withUnsafeBufferPointer { gate.accepts($0) }, "continuous color/range change rejected")
    gate.reset()
    check(!changed.withUnsafeBufferPointer { gate.accepts($0) }, "recreated decoder preserves opening color/range")
    check(key.withUnsafeBufferPointer { gate.accepts($0) }, "original keyframe accepted after reset")
  }
  print("VP9 headers: \(checks) checks, \(failures) failures");if failures>0{exit(1)}
 }
}
