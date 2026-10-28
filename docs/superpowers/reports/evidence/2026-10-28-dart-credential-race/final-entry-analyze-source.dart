// One app launch covers the sequential and concurrent credential contracts.
import 'apple_dash_credential_failure_test.dart' as failure;
import 'apple_dash_credential_race_test.dart' as race;

void main() {
  failure.main();
  race.main();
}
