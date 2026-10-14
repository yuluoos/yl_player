import Foundation
// Standalone harness substitutes only the host's error envelope. XML, clocks,
// sidx, origin policy and both admission paths compile from production sources.
struct NativePlayerError: Error {
  let category: String
  let code: String
  let message: String
}
