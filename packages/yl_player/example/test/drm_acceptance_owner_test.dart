import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import '../integration_test/support/drm_acceptance_owner.dart';

void main() {
  test('late creation after timeout cleanup is released once', () async {
    final released = <Object>[];
    final owner = DrmAcceptanceOwner<Object>(
      release: (value) async => released.add(value),
    );
    final pending = Completer<Object>();
    final acquired = owner.acquire(pending.future);
    await owner.close(unmount: () async {});
    final resource = Object();
    final rejected = expectLater(acquired, throwsStateError);
    pending.complete(resource);
    await rejected;
    expect(released, [resource]);
    await owner.close(unmount: () async {});
    expect(released, [resource]);
  });

  test('unmount failure still releases acquired player', () async {
    final released = <Object>[];
    final owner = DrmAcceptanceOwner<Object>(
      release: (value) async => released.add(value),
    );
    final resource = await owner.acquire(Future.value(Object()));
    await expectLater(
      owner.close(unmount: () async => throw StateError('unmount')),
      throwsStateError,
    );
    expect(released, [resource]);
    await owner.close(unmount: () async {});
    expect(released, [resource]);
  });
}
