@testable import yl_player_apple
import AppKit
import AVFAudio
import Foundation
import VideoToolbox
import XCTest
import YlFFmpegBridge

final class YlMacosAudioTests: XCTestCase {

  func testOpusTrimmingPrerollResetAndSafeFailure() throws {
    let converter = YlAppleCompressedAudioConverter()
    let head = Data([79,112,117,115,72,101,97,100,1,2,56,1,128,187,0,0,0,0,0])
    try converter.configure(stream: .init(codec: .opus, sampleRate: 48000,
      channelCount: 2, magicCookie: head, generation: 9))
    let silence = Data([0xfc, 0xff, 0xfe])
    let first = YlCompressedAudioPacket(data: silence, ptsUs: -6500,
      durationUs: Int64.max, generation: 9, skipSamples: 312)
    let estimate = converter.estimateOutput(for: first)
    XCTAssertEqual(estimate.byteCount, 5760 * 8)
    XCTAssertEqual(estimate.durationUs, 120000)
    let trimmed = try XCTUnwrap(converter.convert(packet: first))
    XCTAssertEqual(trimmed.ptsUs, 0)
    XCTAssertEqual(trimmed.durationUs, 13500)
    XCTAssertEqual((trimmed.payload as? AVAudioPCMBuffer)?.frameLength, 648)
    XCTAssertEqual(trimmed.generation, 9)
    converter.reset()
    XCTAssertNil(try converter.convert(packet: .init(data: silence, ptsUs: 1000000,
      durationUs: 20000, generation: 9, presentationStartUs: 1030000)))
    let cut = try XCTUnwrap(converter.convert(packet: .init(data: silence, ptsUs: 1020000,
      durationUs: 20000, generation: 9, discardSamples: 48, presentationStartUs: 1030000)))
    XCTAssertEqual(cut.ptsUs, 1030000)
    XCTAssertEqual(cut.durationUs, 9000)
    XCTAssertEqual((cut.payload as? AVAudioPCMBuffer)?.frameLength, 432)
    converter.reset()
    let reset = try XCTUnwrap(converter.convert(packet: first))
    XCTAssertEqual((reset.payload as? AVAudioPCMBuffer)?.frameLength, 648)
    XCTAssertThrowsError(try converter.convert(packet: .init(data: Data([0,255,254]),
      ptsUs: 0, durationUs: 20000, generation: 9))) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "decoder.audio_opus_unsupported")
    }
    for channels in [0,3] {
      XCTAssertThrowsError(try converter.configure(stream: .init(codec: .opus,
        sampleRate: 48000, channelCount: channels, magicCookie: head, generation: 9)))
    }
  }

  func testFLACDecodesExactMono16AndStereo24SamplesIncludingShortFinalPacketAndReset() throws {
    // Owned integer ramps, 1000 frames at 48 kHz. Host FFmpeg 8.0.1 FLAC,
    // -frame_size 576; expected PCM is independently computed below.
    let fixtures: [(Int, Int, String, [(Int, String)])] = [
      (16, 1, "AkACQAACEwAClQu4APAAAAPoTudV7k7wxTEl3pHrSkX4Fg==", [(576, "//gqCADmQIrQ5z+pFQ2ZLlypMiRfddbZXXVTIKFHFFOV3X2zZGTGNc95BJJRZhhpx54gqJEkTKFCpYuXMGTJo2cOHTfP35AQkJERkhISkxOTlBSUlRlZYWFpcXl5gYmJkZmhoamxubmcHJydHZ4eHp8fn4gEIhEQjEgkOikYjkckEkkkolkwmE0nE8nlAolI6kUyoVCqViuVywWS0Wi2XC4XS8Xzr5gMJiMRjMhkMpmM5nNBpNRqNZsO2G03G83nA4nI5HM6HQ6nY7nc8Hk70ej2fD4fT8fz+IAgiEIQhiIIgiiMhDkORBEkURRFkYRhGkcR5HkgSJJEkSaEoShKksS5LkwTJNE0TZOE4TpPE+T5QIUJRFEUZSFIUpTFOU5UFSVRVFWVhWFahXFeV5YFiWRZFmWhaFqWxbluXBcl0XSF2XheF6Xxfl+YBgmEYRhmIYhimMY5joZBkmUZRlmYZhmmcZ5nmgaJpGkaZqGohqmsa5rmwbJtG0bZuG4bpvG+b5wHCcSHEcZyHIcpzHOc50HSdR1HWdh2Hadx3od54HieR5Hmeh6Hqex7nufB8n0fR9n4n+P6/z/v+QAgJAiBEDIIQQgpBiDkHIQQlKFEKIWQwhhDSHEPIeRAiJEiJETIoRQipFkouRcjBGSNEaI2RwjhHSPEfI+SAkJIiREjZJIkkSSpJkk6ScAAAACTfArgUwJ4E8CWBHAhgQwH4DsBsxYk880skl7VrT/7cnMVmchCmOcQUYYcIXjrz75AiSJEyhQqWLlzBkrRo2cOHTx8+ICIkJCYoKCosZOTlBSVFRWWFhaXF5eYGJkZGZmhoamxubnBydHR2eHh6fH5+IDoJCIRDIhEIpGI5HJBJJRKJZMJhNBLVQ=="), (424, "//h6CAEBp8VA1LDnP4oN/T2+Pr8/kAgkIhkQiEUjEckEklEsmE0nE8oFEpFMqFUrFcsFktFsuF0vF8wGExGMyGUzGc0Gk1Gs2I7Xc73g8Xk83o9Xs93w+X0+34/X8/yAIEgiDIQhSGIciCJIoiyMI0jiOI8kCRJIkyUJUliXJgmSaJsnCdJ4nygQoSiKMpClKYpyoKkqirKwrSuK8sCxLIsy0LUti3LguS6LsvC9L4vzAMEwjDMQxTGMcyDJMoyzMM0zjPNA0TSNM1DVQ1jXNg2TZNo2zcN03jfOA4TiOM5DlOY5zoOk6jrOw7TuO88DxPI8z0PU9j3Pg+T6Ps/D9P4/xACBEEIMQghRDCHEQIlKFELIYQ0hxDyIERIkRMihFSLEXIwRkjRGyOEdI8R8kBISREjJGSQkpJiTkoJSSolZLCWkuJeTAmJMiZk0JqTYm5OCck6J2Twnq6fKfqgKgqhKhqiKiqjKjqkKkqlKlqmKmqnKnqoKoqpKpqqKqqrKrqsKsqtKtquKuqvKvqwAAAAAAAAAAn9ibiZiZiXiViTiRiPiNiLiJiHiFiDiBh/h9Z7eXd1c3FvbWtpZ2VjYV9dW1lXVVNRT01LSUdFQ0H/99+e/Xnx37denPlx4b923Zr1aa43210zyyxwwRSTUVWXYZabcdefIESRMoVLFzBk0bOHTx8QERITFBUWFxgZGgABr")]),
      (24, 2, "AkACQAADnwAEzQu4A3AAAAPoBAnqjMe7WPsv7qc4O7XlIA==", [(576, "//gqHADlToXuAIYM74Yr3oZKzYZpvIaIq4anmobGieYtjJLmtdrdCbSduaJHftugZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWTpjEh5jjdpkCZZkhVJlAQ5lfMpl+IZmdEOYtjZLktdrdCbSduaJHftugZSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJSUlJS6Ks="), (424, "//h6HAEBp/pOy4fAy6avy8Wey+SNzAN8zCJrzEFazGBJ5i2Dkwq1kt2Js8264kW+3SBnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJyTt5eR959Nt6cJd67FN7aA9748t8X4d820OYtu5JUtlrdEbLdv+I2Pu+gZOTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OTtk6")]),
    ]
    for (bits, channels, encodedCookie, packets) in fixtures {
      let converter = YlAppleCompressedAudioConverter()
      let cookie = try XCTUnwrap(Data(base64Encoded: encodedCookie))
      let stream = YlAudioStreamConfiguration(codec: .flac, sampleRate: 48_000,
        channelCount: channels, magicCookie: cookie, generation: 3)
      try converter.configure(stream: stream)
      for _ in 0..<2 {
        var sampleIndex = 0
        for (frames, encoded) in packets {
          let packet = YlCompressedAudioPacket(data: try XCTUnwrap(Data(base64Encoded: encoded)),
            ptsUs: Int64(sampleIndex) * 1_000_000 / 48_000,
            durationUs: Int64.max, generation: 3)
          let estimate = converter.estimateOutput(for: packet)
          XCTAssertLessThanOrEqual(estimate.byteCount, 577 * channels * 4)
          XCTAssertLessThanOrEqual(estimate.durationUs, 12_000)
          let result = try XCTUnwrap(converter.convert(packet: packet))
          let pcm = try XCTUnwrap(result.payload as? AVAudioPCMBuffer)
          XCTAssertEqual(Int(pcm.frameLength), frames)
          XCTAssertEqual(pcm.frameCapacity, UInt32(frames))
          XCTAssertEqual(result.ptsUs, packet.ptsUs)
          XCTAssertEqual(result.generation, 3)
          XCTAssertEqual(result.byteCount, frames * channels * 4)
          let samples = try XCTUnwrap(pcm.floatChannelData)
          for frame in 0..<frames {
            for channel in 0..<channels {
              let index = sampleIndex + frame
              let integer = bits == 16 ? (index * 137) % 60000 - 30000
                : (index * 7919 + channel * 1234567) % 16000000 - 8000000
              let expected = Float(integer) / (bits == 16 ? 32768 : 8388608)
              let actual = pcm.format.isInterleaved ? samples[0][frame * channels + channel] : samples[channel][frame]
              XCTAssertEqual(actual, expected, accuracy: 0.0000001)
            }
          }
          sampleIndex += frames
        }
        XCTAssertEqual(sampleIndex, 1000)
        converter.reset()
      }
      for badPacket in [Data(), Data([0xff, 0xf8, 0x70, 0x08, 0, 0xff, 0xff, 0]),
                        Data([0xff, 0xf8, 0x70, 0x08, 0xff, 0, 0])] {
        XCTAssertThrowsError(try converter.convert(packet: YlCompressedAudioPacket(
          data: badPacket, ptsUs: 0, durationUs: 0, generation: 3)))
      }
      for badCookie in [Data(), cookie.dropLast(), cookie + Data([0])] {
        XCTAssertThrowsError(try converter.configure(stream: YlAudioStreamConfiguration(
          codec: .flac, sampleRate: 48_000, channelCount: channels,
          magicCookie: Data(badCookie), generation: 3)))
      }
      for (rate, count) in [(44_100.0, channels), (48_000.0, 6)] {
        XCTAssertThrowsError(try converter.configure(stream: YlAudioStreamConfiguration(
          codec: .flac, sampleRate: rate, channelCount: count, magicCookie: cookie, generation: 3)))
      }
      for offset in [0, 1, 10, 11, 12, 13] {
        var invalid = cookie
        invalid[offset] = offset == 13 ? (invalid[offset] ^ 0x10) : 0xff
        XCTAssertNil(YlFLACConfiguration(stream: YlAudioStreamConfiguration(
          codec: .flac, sampleRate: 48_000, channelCount: channels, magicCookie: invalid, generation: 3)),
          "Mutated STREAMINFO offset \(offset)")
      }
    }
  }


  func testDolbySurroundConvertsCenterWithoutChangingSpeakerOrderAndResets() throws {
    // Synthetic center-only 440 Hz tones, AC-3 / E-AC-3, 48 kHz 5.1(side).
    let fixtures: [(YlAudioCodec, String)] = [
      (.ac3, "C3f6xhRA6/hAPv4Afw8PCEBAQfw8PD+Hh4fw8PDVXVeG+/51fPnz58+fPnz4g0Tx/IkOu+fPnz4/51fPnz58+fPnz4/51fPnz58+fPnz4/51fPnz58+fPnz4/51y/whAgQIECBIAAAAAG+fPG2222228ePHju8gVWXWXW0rDfDTPR8M4sx2lal4f/pdJCaKBoiN2DioVUAAAAN8+fNtttttt48ePHdwAAAA3z582222223jx48d3AAAADfPm2222228ePHju4AAAAbwHwEACob58/fPgAAAABvn0BttttttvHjx47uvbR1l1l1lxrdIHOadej48Vip8s9VcIz9czAvfSwR9Gp1eAAAAG+fPm2222228ePHju4AAAAb58+bbbbbbbx48eO7gAAABvnzbbbbbbePHjx3cAAAAN4D4AAAAAAAAN8+eNtttttt48ePHd8A8AWk2k2kymAmm2kPR9drPCizv0ErSxEToRIEVGQRUxAAAAAA3z582222223jx48d3AAAADfPnzbbbbbbePHjx3cAAAAN8+bbbbbbbx48eO7gAAABvAfAAAAAAAABvnz9ttttttvHjx47ulwnMususustpukDXoV+eOIUBOLYFXsgrgZ00KFy2AvUKqAAAAG+fPm2222228ePHju4AAAAb58+bbbbbbbx48eO7gAAABvnzbbbbbbePHjx3cAAAAN4D4CABUN8+fV3wAAAAA3z5+2222223jx48d3dty6y4040404mc1oVsvxzFw15WXZSZoxdFhftW0i+Kq82sAAAADfPm2222228ePHju4AAAAb58+bbbbbbbx48eO7gAAABvnz5ttttttvHjx47uAAAAGD4AAAAAAAAN8+eNtttttt48ePHd6o9kXE2oyoyo6cBNAki8f4j2WWoJtGZ7wuwXqKUIwyJKxAAAAAA3z5ttttttvHjx47uAAAAG+fPm2222228ePHju4AAAAb58+bbbbbbbx48eO7gAAABgAAAAAAAAAAAAAAAAAAAAAAF2m"),
      (.eac3, "C3cBfz+HwAAgkAAAAgAAAAQYHwB+Hh4BAQEH4eHh+Hh4fh4eFV4b7/nV8+fPnz58+fPiDRPH8iQ6758+fPj/nV8+fPnz58+fPj/nV8+fPnz58+fPj/nV8+fPnz58+fPj/nUAAAAAG+fPn7bbbbbePHjx4XXL9y/em9uHmHmHmXWXWPhnFmO0rUvD/9LpITP0DREbsBxaMqsCpAAAADfPnz5tttttvHjx48AAAADfPnz5tttttvHjx48AAAADfPnzbbbbbePHjx4AAAAG8AVDfPn758AAAABvnz56222223jx48ee1LXSlz9ze3N6dHmHmHmXa9Hx4rFT5Z6q4Rn65mAXvpYIvY2K2coFVIAAAAN8+fPm222228ePHjwAAAAN8+fPm222228ePHjwAAAAN8+fNttttt48ePG4AAAAbwAAAAABvnz58222223jx48eIQA2jMBjMM7szqwNgNiLST0fXazwos79BK0sRE6FEgRUZAhXipqBSwAAAAAN8+fPm222228ePHjwAAAAN8+fPm222228ePHjwAAAAN8+fNttttt48ePG4AAAAbwAAAAABvnz5+222223jx48eZ9pH6TV4muDa3N8w8w8w6wr88cQoCcWwKvZBXAzmaFC5bAF49o0sQKkAAAAN8+fPm222228ePHjwAAAAN8+fPm222228ePHjwAAAAN8+fNttttt48ePG4AAAAbwBUN8+fV3wAAAAG+fPnrbbbbbePHjx4Dj9y/cvnR6dHp0eWXWXWXbZfjmLhrysuykzRi6LIv2raRfhWKWjWtakAAAAN8+fPm222228ePHjwAAAAN8+fPm222228ePHjwAAAAN8+fNttttt48ePG4AAAAbwAAAAABvnz5+222223jx48eHQL2l8Ji8QqtDq0O4i4i5FJF4/xHsstQTaMz3hdhL1FKEUKSOyagUsAAAAADfPnz5tttttvHjx48AAAADfPnz5tttttvHjx48AAAADfPnzbbbbbePHjxuAAAAG8AAAAAAAE9R")
    ]
    for (codec, encoded) in fixtures {
      let converter = YlAppleCompressedAudioConverter()
      try converter.configure(stream: YlAudioStreamConfiguration(
        codec: codec, sampleRate: 48_000, channelCount: 6,
        magicCookie: Data(), generation: 1, channelMask: 0x60f
      ))
      let data = try XCTUnwrap(Data(base64Encoded: encoded))
      for _ in 0..<2 {
        var decoded: YlScheduledAudioBuffer?
        for index in 0..<4 {
          decoded = try converter.convert(packet: YlCompressedAudioPacket(
            data: data, ptsUs: Int64(index) * 32_000, durationUs: 32_000, generation: 1))
          if decoded != nil { break }
        }
        let buffer = try XCTUnwrap(decoded)
        let pcm = try XCTUnwrap(buffer.payload as? AVAudioPCMBuffer)
        XCTAssertGreaterThan(pcm.frameLength, 0)
        XCTAssertEqual(pcm.format.channelCount, 6)
        let samples = try XCTUnwrap(pcm.floatChannelData)
        var energy = [Double](repeating: 0, count: 6)
        for frame in 0..<Int(pcm.frameLength) {
          for channel in 0..<6 {
            let value = pcm.format.isInterleaved ? samples[0][frame * 6 + channel] : samples[channel][frame]
            energy[channel] += Double(value * value)
          }
        }
        XCTAssertGreaterThan(energy[2], 1, "Center signal must remain in the center channel")
        for channel in [0, 1, 3, 4, 5] { XCTAssertLessThan(energy[channel], energy[2] * 0.001) }
        XCTAssertEqual(buffer.byteCount, Int(pcm.frameLength) * 6 * MemoryLayout<Float>.size)
        converter.reset()
      }
    }
  }

  func testDolbyAudioRejectsMissingOrMismatchedSpeakerLayouts() {
    for codec: YlAudioCodec in [.ac3, .eac3] {
      for mask: UInt64 in [0, 3, 0x8000000000000000] {
        let converter = YlAppleCompressedAudioConverter()
        XCTAssertThrowsError(try converter.configure(stream: YlAudioStreamConfiguration(
          codec: codec, sampleRate: 48_000, channelCount: 6,
          magicCookie: Data(), generation: 1, channelMask: mask)))
      }
    }
  }

  func testDolbySurroundSystemOutputCanSwitchToAAC() throws {
    let renderer = YlAudioRenderer()
    defer { renderer.dispose() }
    for codec: YlAudioCodec in [.ac3, .eac3, .aac] {
      try renderer.configure(stream: YlAudioStreamConfiguration(
        codec: codec, sampleRate: 48_000, channelCount: 6,
        magicCookie: codec == .aac ? Data([0x11, 0xb0]) : Data(),
        generation: 1, channelMask: 0x60f))
    }
  }


  func testAACSurroundRejectsMissingOrMismatchedChannelConfiguration() {
    for cookie in [Data(), Data([0x11]), Data([0x11, 0x90])] {
      let converter = YlAppleCompressedAudioConverter()
      XCTAssertThrowsError(try converter.configure(stream: YlAudioStreamConfiguration(
        codec: .aac, sampleRate: 48_000, channelCount: 6,
        magicCookie: cookie, generation: 1
      )))
    }
  }

  func testAACSurroundConvertsAllSixChannelsWithExplicitLayout() throws {
    let converter = YlAppleCompressedAudioConverter()
    try converter.configure(stream: YlAudioStreamConfiguration(
      codec: .aac, sampleRate: 48_000, channelCount: 6,
      magicCookie: Data([0x11, 0xb0]), generation: 1
    ))
    // Synthetic AAC-LC 5.1 silence, generated from anullsrc (48 kHz).
    let data = Data([0x01, 0x18, 0x20, 0x01, 0x08, 0x80, 0x23, 0x04, 0x60,
                     0x23, 0x10, 0x04, 0x60, 0x8c, 0x0c, 0x23, 0x00, 0x00, 0xe0])
    var decoded: YlScheduledAudioBuffer?
    for index in 0..<4 {
      decoded = try converter.convert(packet: YlCompressedAudioPacket(
        data: data, ptsUs: Int64(index) * 21_333, durationUs: 21_333, generation: 1
      ))
      if decoded != nil { break }
    }
    let buffer = try XCTUnwrap(decoded)
    let pcm = try XCTUnwrap(buffer.payload as? AVAudioPCMBuffer)
    XCTAssertEqual(pcm.frameLength, 1024)
    XCTAssertEqual(pcm.format.channelCount, 6)
    XCTAssertEqual(pcm.format.channelLayout?.layoutTag, kAudioChannelLayoutTag_AAC_5_1)
    XCTAssertEqual(buffer.byteCount, 1024 * 6 * MemoryLayout<Float>.size)
  }

  func testAACSurroundConfiguresTheSystemOutputAndCanReconfigureStereo() throws {
    let renderer = YlAudioRenderer()
    defer { renderer.dispose() }
    try renderer.configure(stream: YlAudioStreamConfiguration(
      codec: .aac, sampleRate: 48_000, channelCount: 6,
      magicCookie: Data([0x11, 0xb0]), generation: 1
    ))
    try renderer.configure(stream: YlAudioStreamConfiguration(
      codec: .aac, sampleRate: 44_100, channelCount: 2,
      magicCookie: Data([0x12, 0x10]), generation: 2
    ))
  }

  private final class TestAudioConverter: YlAudioPacketConverting {
    func configure(stream: YlAudioStreamConfiguration) throws {}

    func estimateOutput(
      for packet: YlCompressedAudioPacket
    ) -> YlAudioBufferEstimate {
      YlAudioBufferEstimate(durationUs: 250_000, byteCount: 1_000)
    }

    func convert(
      packet: YlCompressedAudioPacket
    ) throws -> YlScheduledAudioBuffer? {
      YlScheduledAudioBuffer(
        payload: NSObject(),
        ptsUs: packet.ptsUs,
        durationUs: 250_000,
        byteCount: 1_000,
        generation: packet.generation
      )
    }
  }


  private final class TestAudioOutput: YlAudioOutputDriving {
    var volume: Float = 1
    var rate: Float = 1
    let renderedAudioTime: YlRenderedAudioTime? = nil
    private(set) var playCount = 0
    private(set) var isPlaying = false
    var onSchedule: (() -> Void)?
    private var completions: [() -> Void] = []

    func configure(sampleRate: Double, channelCount: Int) throws {}
    func schedule(_ buffer: YlScheduledAudioBuffer, completion: @escaping () -> Void) {
      completions.append(completion)
      onSchedule?()
    }
    func play() throws { playCount += 1; isPlaying = true }
    func pause() { isPlaying = false }
    func reset() {}
    func dispose() {}

    func completeNextBuffer() {
      guard !completions.isEmpty else { return }
      completions.removeFirst()()
    }
  }


  func testSystemAudioKeepsNeutralPitchAndRealtimeSmoothnessAcrossRateChanges() throws {
    let output = YlSystemAudioOutput()
    defer { output.dispose() }

    output.rate = 3

    let timePitch = try XCTUnwrap(
      Mirror(reflecting: output).children.first {
        $0.label == "timePitch"
      }?.value as? AVAudioUnitTimePitch
    )
    XCTAssertEqual(timePitch.rate, 3)
    XCTAssertEqual(timePitch.pitch, 0)
    XCTAssertEqual(timePitch.overlap, 8)

    output.rate = 1
    XCTAssertEqual(timePitch.rate, 1)
    XCTAssertEqual(timePitch.pitch, 0)
    XCTAssertEqual(timePitch.overlap, 8)
  }


  func testPauseDuringAudioSchedulingCancelsPendingAutomaticRestart() throws {
    let output = TestAudioOutput()
    let renderer = YlAudioRenderer(converter: TestAudioConverter(), output: output)
    try renderer.configure(stream: YlAudioStreamConfiguration(
      codec: .aac, sampleRate: 48_000, channelCount: 2,
      magicCookie: Data(), generation: 1
    ))
    try renderer.play()
    output.onSchedule = { renderer.pause() }

    XCTAssertEqual(try renderer.enqueue(packet: YlCompressedAudioPacket(
      data: Data([1]), ptsUs: 0, durationUs: 250_000, generation: 1
    )), .scheduled)

    XCTAssertFalse(output.isPlaying, "A completed pause must cancel the automatic restart.")
  }


  func testConcurrentPauseFinishesAfterAnInProgressAudioEnqueue() throws {
    let output = TestAudioOutput()
    let renderer = YlAudioRenderer(converter: TestAudioConverter(), output: output)
    try renderer.configure(stream: YlAudioStreamConfiguration(
      codec: .aac, sampleRate: 48_000, channelCount: 2,
      magicCookie: Data(), generation: 1
    ))
    try renderer.play()
    let entered = DispatchSemaphore(value: 0)
    let releaseSchedule = DispatchSemaphore(value: 0)
    let enqueued = DispatchSemaphore(value: 0)
    let paused = DispatchSemaphore(value: 0)
    output.onSchedule = {
      entered.signal()
      _ = releaseSchedule.wait(timeout: .now() + 2)
    }
    DispatchQueue.global().async {
      defer { enqueued.signal() }
      do {
        _ = try renderer.enqueue(packet: YlCompressedAudioPacket(
          data: Data([1]), ptsUs: 0, durationUs: 250_000, generation: 1
        ))
      } catch { XCTFail("Unexpected enqueue error: \(error)") }
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    DispatchQueue.global().async { renderer.pause(); paused.signal() }
    // A concurrent pause cannot be overtaken by the pending restart.
    XCTAssertEqual(paused.wait(timeout: .now() + 0.05), .timedOut)
    releaseSchedule.signal()
    XCTAssertEqual(enqueued.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(paused.wait(timeout: .now() + 1), .success)
    XCTAssertFalse(output.isPlaying)
  }


  func testAACPacketFromFallbackFixtureConvertsToPCM() throws {
    let exampleRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fixture = exampleRoot.appendingPathComponent(
      "assets/test_media/h264_aac.flv"
    )
    var context: YLFMediaContextRef?
    var mediaInfo = YLFMediaInfo()
    let openResult = fixture.withUnsafeFileSystemRepresentation { path in
      ylf_open_local(path, &context, &mediaInfo)
    }
    XCTAssertEqual(openResult, Int32(YLFResultOK))
    guard let context else {
      XCTFail("The FLV fixture did not open.")
      return
    }
    var ownedContext: YLFMediaContextRef? = context
    defer { ylf_close(&ownedContext) }

    var audioStream: YLFStreamInfo?
    for index in 0..<mediaInfo.stream_count {
      var stream = YLFStreamInfo()
      if ylf_copy_stream_info(context, index, &stream) == 0,
         Int(stream.kind) == YLFStreamAudio,
         Int(stream.codec) == YLFCodecAAC {
        audioStream = stream
        break
      }
    }
    guard let audioStream else {
      XCTFail("The FLV fixture has no AAC stream.")
      return
    }

    let cookieSize = ylf_stream_codec_config_size(context, audioStream.index)
    var cookie = [UInt8](repeating: 0, count: cookieSize)
    XCTAssertEqual(
      ylf_copy_stream_codec_config(
        context,
        audioStream.index,
        &cookie,
        cookie.count
      ),
      0
    )
    let converter = YlAppleCompressedAudioConverter()
    try converter.configure(stream: YlAudioStreamConfiguration(
      codec: .aac,
      sampleRate: Double(audioStream.sample_rate),
      channelCount: Int(audioStream.channel_count),
      magicCookie: Data(cookie),
      generation: 1
    ))

    for _ in 0..<256 {
      var packetRef: YLFPacketRef?
      let readResult = ylf_read_packet(context, &packetRef)
      guard readResult == Int32(YLFResultOK), let packet = packetRef else { break }
      let streamIndex = ylf_packet_stream_index(packet)
      guard streamIndex == audioStream.index,
            let bytes = ylf_packet_data(packet) else {
        ylf_packet_release(&packetRef)
        continue
      }
      let compressed = YlCompressedAudioPacket(
        data: Data(bytes: bytes, count: ylf_packet_size(packet)),
        ptsUs: ylf_packet_pts_us(packet),
        durationUs: ylf_packet_duration_us(packet),
        generation: 1
      )
      ylf_packet_release(&packetRef)

      if let decoded = try converter.convert(packet: compressed) {
        XCTAssertGreaterThan(decoded.durationUs, 0)
        XCTAssertGreaterThan(decoded.byteCount, 0)
        XCTAssertEqual(decoded.ptsUs, 62_000)
        return
      }
    }

    XCTFail("The FLV fixture produced no AAC packet.")
  }


  func testAACConverterDoesNotConsumeCompressedPacketsWithoutPCMOutput() throws {
    let exampleRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fixture = exampleRoot.appendingPathComponent(
      "assets/test_media/h264_aac.flv"
    )
    var context: YLFMediaContextRef?
    var mediaInfo = YLFMediaInfo()
    XCTAssertEqual(
      fixture.withUnsafeFileSystemRepresentation { path in
        ylf_open_local(path, &context, &mediaInfo)
      },
      Int32(YLFResultOK)
    )
    let openedContext = try XCTUnwrap(context)
    var ownedContext: YLFMediaContextRef? = openedContext
    defer { ylf_close(&ownedContext) }

    var audioStream: YLFStreamInfo?
    for index in 0..<mediaInfo.stream_count {
      var stream = YLFStreamInfo()
      if ylf_copy_stream_info(openedContext, index, &stream) == 0,
         Int(stream.kind) == YLFStreamAudio,
         Int(stream.codec) == YLFCodecAAC {
        audioStream = stream
        break
      }
    }
    let stream = try XCTUnwrap(audioStream)
    let cookieSize = ylf_stream_codec_config_size(openedContext, stream.index)
    var cookie = [UInt8](repeating: 0, count: cookieSize)
    XCTAssertEqual(
      ylf_copy_stream_codec_config(
        openedContext,
        stream.index,
        &cookie,
        cookie.count
      ),
      0
    )
    let converter = YlAppleCompressedAudioConverter()
    try converter.configure(stream: YlAudioStreamConfiguration(
      codec: .aac,
      sampleRate: Double(stream.sample_rate),
      channelCount: Int(stream.channel_count),
      magicCookie: Data(cookie),
      generation: 1
    ))

    var compressedPacketCount = 0
    var pcmBufferCount = 0
    while compressedPacketCount < 120 {
      var packetRef: YLFPacketRef?
      guard ylf_read_packet(openedContext, &packetRef) == Int32(YLFResultOK),
            let packet = packetRef else { break }
      guard ylf_packet_stream_index(packet) == stream.index,
            let bytes = ylf_packet_data(packet) else {
        ylf_packet_release(&packetRef)
        continue
      }
      let compressed = YlCompressedAudioPacket(
        data: Data(bytes: bytes, count: ylf_packet_size(packet)),
        ptsUs: ylf_packet_pts_us(packet),
        durationUs: ylf_packet_duration_us(packet),
        generation: 1
      )
      ylf_packet_release(&packetRef)
      compressedPacketCount += 1
      if try converter.convert(packet: compressed) != nil {
        pcmBufferCount += 1
      }
    }

    XCTAssertGreaterThan(compressedPacketCount, 50)
    XCTAssertGreaterThanOrEqual(
      pcmBufferCount,
      compressedPacketCount - 1,
      "compressed=\(compressedPacketCount), pcm=\(pcmBufferCount)"
    )
  }


  func testMacOSAudioUsesNonInterleavedPCMAndCountsEveryChannel() {
    XCTAssertFalse(YlAudioFormatPolicy.usesInterleavedPCM)
    XCTAssertEqual(
      YlAudioFormatPolicy.byteCount(
        frameCount: 100,
        bytesPerFrame: 4,
        channelCount: 2
      ),
      800
    )
  }


  func testAudioRendererPreservesWallClockBufferAtThreeTimesSpeed() throws {
    let renderer = YlAudioRenderer(
      maxScheduledDurationUs: 500_000,
      maxScheduledBytes: 10_000,
      converter: TestAudioConverter(),
      output: TestAudioOutput()
    )
    try renderer.configure(stream: YlAudioStreamConfiguration(
      codec: .aac,
      sampleRate: 48_000,
      channelCount: 2,
      magicCookie: Data([0x12, 0x10]),
      generation: 1
    ))
    renderer.setRate(3)
    let packet = YlCompressedAudioPacket(
      data: Data([1]),
      ptsUs: 0,
      durationUs: 250_000,
      generation: 1
    )

    for _ in 0..<6 {
      XCTAssertEqual(try renderer.enqueue(packet: packet), .scheduled)
    }
    XCTAssertEqual(renderer.scheduledDurationUs, 1_500_000)
    XCTAssertEqual(
      try renderer.enqueue(packet: packet),
      .wouldExceedDuration
    )
  }


  func testFallbackAudioBufferKeepsOneSecondOfHeadroomAtThreeTimesSpeed() throws {
    let renderer = YlAudioRenderer(
      bufferBudget: YlFallbackBufferBudget(
        networkBytes: 1_000,
        scheduledAudioBytes: 100_000,
        inFlightPacketBytes: 1_000
      ),
      converter: TestAudioConverter(),
      output: TestAudioOutput()
    )
    try renderer.configure(stream: YlAudioStreamConfiguration(
      codec: .aac,
      sampleRate: 48_000,
      channelCount: 2,
      magicCookie: Data([0x12, 0x10]),
      generation: 1
    ))
    renderer.setRate(3)
    let packet = YlCompressedAudioPacket(
      data: Data([1]),
      ptsUs: 0,
      durationUs: 250_000,
      generation: 1
    )

    for _ in 0..<12 {
      XCTAssertEqual(try renderer.enqueue(packet: packet), .scheduled)
    }
    XCTAssertEqual(renderer.scheduledDurationUs, 3_000_000)
    XCTAssertEqual(
      try renderer.enqueue(packet: packet),
      .wouldExceedDuration
    )
  }


  func testAudioRendererRestartsOutputAfterTheRunningQueueDrains() throws {
    let output = TestAudioOutput()
    let renderer = YlAudioRenderer(
      maxScheduledDurationUs: 500_000,
      maxScheduledBytes: 10_000,
      converter: TestAudioConverter(),
      output: output
    )
    try renderer.configure(stream: YlAudioStreamConfiguration(
      codec: .aac,
      sampleRate: 48_000,
      channelCount: 2,
      magicCookie: Data([0x12, 0x10]),
      generation: 1
    ))
    let packet = YlCompressedAudioPacket(
      data: Data([1]),
      ptsUs: 0,
      durationUs: 250_000,
      generation: 1
    )

    XCTAssertEqual(try renderer.enqueue(packet: packet), .scheduled)
    try renderer.play()
    XCTAssertEqual(output.playCount, 1)

    output.completeNextBuffer()
    XCTAssertEqual(renderer.underrunCount, 1)
    XCTAssertEqual(try renderer.enqueue(packet: packet), .scheduled)
    XCTAssertEqual(output.playCount, 2)
  }


  func testAudioCatalogExposesAACAndMP3Selection() {
    var aac = YLFStreamInfo()
    aac.index = 3
    aac.kind = Int32(YLFStreamAudio)
    aac.codec = Int32(YLFCodecAAC)
    var mp3 = YLFStreamInfo()
    mp3.index = 4
    mp3.kind = Int32(YLFStreamAudio)
    mp3.codec = Int32(YLFCodecMP3)

    let tracks = YlFallbackTrackCatalog.audioTracks(
      streams: [aac, mp3],
      selectedIndex: mp3.index,
      codecName: { Int($0.codec) == YLFCodecMP3 ? "MP3" : "AAC" }
    )

    XCTAssertEqual(tracks[0].codec, "AAC")
    XCTAssertEqual(tracks[1].codec, "MP3")
    XCTAssertEqual(tracks[1].isSelected, true)
  }

}
