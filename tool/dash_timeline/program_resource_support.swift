import Foundation
// Standalone harness substitutes only the host's error envelope. XML, clocks,
// sidx, origin policy and both admission paths compile from production sources.
struct NativePlayerError: Error {
  let category: String
  let code: String
  let message: String
}

// Configuration bridge adapters only; production request configuration/policy runs.
struct YlAppleNetworkOptions {
  let connectTimeoutMs: Int64, readTimeoutMs: Int64, baseRetryDelayMs: Int64, maxRetryDelayMs: Int64
  let maxRetries: Int, maxRedirects: Int
}
func int64(_ value: Any??) -> Int64? {
  guard let value = value ?? nil else { return nil }
  return (value as? NSNumber)?.int64Value
}
