import Foundation

func stringMap(_ value: Any?) -> [String: Any?] {
  guard let source = value as? [AnyHashable: Any?] else { return [:] }
  return Dictionary(uniqueKeysWithValues: source.map { (String(describing: $0.key), $0.value) })
}
