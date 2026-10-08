// Standalone error transport only. The ledger and timeline plan are compiled from
// production sources without changes; production diagnostic mapping is not tested.
import Foundation
struct NativePlayerError: Error {
  let category: String
  let code: String
  let message: String
  var diagnostic: String?
}
