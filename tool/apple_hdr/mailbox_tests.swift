import Foundation
import CoreVideo

@main
struct MailboxTests {
  static func main() {
    final class Lifetime {}
    var work: [() -> Void] = []
    let mailbox = YlVideoSurfaceMailbox(schedule: { work.append($0) })
    var buffer: CVPixelBuffer?
    precondition(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2,
      kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
    var first: Lifetime? = Lifetime()
    weak var retired = first
    mailbox.publish(.init(pixelBuffer: buffer!, reservation: first))
    first = nil
    precondition(retired != nil)
    mailbox.publish(.init(pixelBuffer: buffer!, reservation: Lifetime()))
    precondition(retired == nil, "Only the latest undelivered frame is retained")
    precondition(work.count == 1, "No growing main-queue backlog")
    var received: [UInt64] = []
    var frames = 0
    var clears = 0
    mailbox.consume = { frame, clear, disposed, epoch in
      precondition(!disposed)
      frames += frame == nil ? 0 : 1
      clears += clear ? 1 : 0
      received.append(epoch)
    }
    work.removeFirst()()
    let oldEpoch = received[0]
    precondition(mailbox.accepts(oldEpoch))
    mailbox.clear()
    precondition(!mailbox.accepts(oldEpoch), "Old render errors invalidated immediately, before main queue drains")
    mailbox.publish(.init(pixelBuffer: buffer!, reservation: nil))
    precondition(work.count == 1)
    work.removeFirst()()
    precondition(frames == 2 && clears == 1 && received[1] != oldEpoch)
    mailbox.dispose()
    precondition(!mailbox.accepts(received[1]))
    var closed = false
    mailbox.consume = { frame, clear, disposed, _ in
      precondition(frame == nil && clear && disposed)
      closed = true
    }
    mailbox.publish(.init(pixelBuffer: buffer!, reservation: Lifetime()))
    work.removeFirst()()
    precondition(closed)
    print("PASS: coalescing, retention release, clear+new-frame ordering, old-error epoch fence, disposal")
  }
}
