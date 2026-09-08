import Foundation

func int64(_ value: Any?) -> Int64? {
  if let value = value as? NSNumber { return value.int64Value }
  return value as? Int64
}
