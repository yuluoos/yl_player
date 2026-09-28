/// Owns the test's player, including creation that finishes after a timeout.
final class DrmAcceptanceOwner<T extends Object> {
  DrmAcceptanceOwner({required this.release});
  final Future<void> Function(T) release;
  T? _resource;
  bool _closed = false;

  Future<T> acquire(Future<T> operation) async {
    final resource = await operation;
    if (_closed) {
      await release(resource);
      throw StateError('DRM acceptance owner is closed.');
    }
    _resource = resource;
    return resource;
  }

  Future<void> close({required Future<void> Function() unmount}) async {
    _closed = true;
    final resource = _resource;
    _resource = null;
    try {
      await unmount();
    } finally {
      if (resource != null) await release(resource);
    }
  }
}
