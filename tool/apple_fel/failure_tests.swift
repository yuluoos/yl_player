import Foundation
import YlFFmpegBridge

@main struct FailureTests {
    static func main() throws {
        var failures = [String]()
        var count = 0
        func check(_ input: [String: Any], _ category: AppleFailureCategory, _ code: String) {
            for scope in [AppleFailureScope.command, .player] {
                count += 1
                do { _ = try YlFELFailure.metadata(input); failures.append("invalid input accepted") }
                catch {
                    let published = YlAppleSafeDiagnostics.failure(error, scope: scope)
                    if published.category != category || published.code != code || published.scope != scope ||
                        published.retryable || published.diagnosticId.isEmpty {
                        failures.append("incorrect published failure: \(published.category) \(published.code)")
                    }
                    if published.message.contains("private.example") { failures.append("private metadata leaked") }
                }
            }
        }
        let budgetFailure = YlAppleSafeDiagnostics.failure(
            YlFELFailure.make("resource.network_buffer_limit", "opening probe budget"), scope: .command)
        count += 1
        if budgetFailure.category != .resource { failures.append("budget exhaustion reported decoder corruption") }
        let malformed = YlAppleSafeDiagnostics.failure(YlFELFailure.make("decoder.dolby_vision_fel_invalid", "private.example"), scope: .command)
        count += 1
        if !malformed.message.contains("Dolby Vision") || malformed.message.contains("private.example") {
            failures.append("malformed FEL lacks a safe specific hint")
        }
        check([:], .decoder, "decoder.dolby_vision_fel_invalid")
        check(["schemaVersion": "https://private.example/?token=secret"], .decoder, "decoder.dolby_vision_fel_invalid")
        check(["schemaVersion": 2], .unsupported, "decoder.dolby_vision_fel_metadata_unsupported")
        for (status, category, code) in [
            (Int32(YLFResultDolbyVisionUnsupported), AppleFailureCategory.unsupported, "decoder.dolby_vision_fel_metadata_unsupported"),
            (Int32(YLFResultVideoConfigurationInvalid), AppleFailureCategory.decoder, "decoder.dolby_vision_fel_invalid")
        ] {
            count += 1
            let failure = YlAppleSafeDiagnostics.failure(YlFELFailure.bridge(status, "access unit"), scope: .player)
            if failure.category != category || failure.code != code { failures.append("bridge status was collapsed") }
        }
        var cropped = metadataFixture()
        cropped["displayMetadata"] = [["level": 5, "values": ["left": 2, "right": 2, "top": 1, "bottom": 1]]]
        _ = try YlFELFailure.metadata(cropped, frameSize: (5, 3))
        for size in [(4, 3), (5, 2), (0, 3), (5, -1)] {
            count += 1
            do { _ = try YlFELFailure.metadata(cropped, frameSize: size); failures.append("empty active area accepted") }
            catch {
                let failure = YlAppleSafeDiagnostics.failure(error, scope: .player)
                if failure.category != .decoder || failure.code != "decoder.dolby_vision_fel_invalid" {
                    failures.append("invalid active area has wrong public failure")
                }
            }
        }
        if !failures.isEmpty {
            failures.forEach { print("FAIL " + $0) }; exit(1)
        }
        print("FEL failure: \(count) public envelope checks passed")
    }
}
