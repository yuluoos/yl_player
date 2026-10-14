part of 'subtitle_resource_io.dart';

DashSubtitleReader createDashReader(YlMediaSource source) {
  validateYlSource(source);
  if (source is! YlFileSource && source is! YlNetworkSource) {
    throw subtitleFailure(YlFailureCodes.subtitleUnsupported);
  }
  if (source is YlNetworkSource) {
    if (source.drm != null || !['http', 'https'].contains(source.uri.scheme)) {
      throw subtitleFailure(YlFailureCodes.policyUnsupported);
    }
    for (final entry in [
      ...source.request.headers.entries,
      ...source.request.credentials.entries,
    ]) {
      final name = entry.key.toLowerCase();
      if ([
            'range',
            'if-range',
            'if-match',
            'if-none-match',
            'if-modified-since',
            'if-unmodified-since',
          ].contains(name) ||
          (name == 'accept-encoding' &&
              entry.value.trim().toLowerCase() != 'identity')) {
        throw subtitleFailure(YlFailureCodes.policyUnsupported);
      }
    }
  }
  return _DashSubtitleReader(source);
}

final class _DashSubtitleReader implements DashSubtitleReader {
  _DashSubtitleReader(this.source);
  final YlMediaSource source;
  final _histories = <String, _NetworkLedger>{};
  final _validators = <Uri, (String, int)>{};
  var _attempts = 0, _received = 0, _uriUnits = 0;
  var _busy = false;
  @override
  Future<DashSubtitleReply> root(SubtitleCancellation token) => read(
    DashSubtitleResource([
      DashSubtitleLocation(
        source is YlFileSource
            ? Uri.file((source as YlFileSource).path)
            : (source as YlNetworkSource).uri,
      ),
    ]),
    token,
    2 * 1024 * 1024,
  );

  @override
  Future<DashSubtitleReply> read(
    DashSubtitleResource resource,
    SubtitleCancellation token,
    int maxBytes,
  ) async {
    token.check();
    if (_busy ||
        maxBytes < 1 ||
        maxBytes > 4 * 1024 * 1024 ||
        resource.locations.isEmpty ||
        resource.locations.length > 16) {
      throw subtitleFailure(YlFailureCodes.subtitleTooLarge);
    }
    final range = resource.range;
    if (range != null &&
        (range.start < 0 ||
            range.length < 1 ||
            range.length > maxBytes ||
            range.start > 0x1fffffffffffff - range.length)) {
      throw subtitleFailure(YlFailureCodes.subtitleTooLarge);
    }
    for (final location in resource.locations) {
      // Validate even references created directly by an internal caller.
      if (source is YlNetworkSource) {
        final root = (source as YlNetworkSource).uri;
        DashSubtitleLocation(root).resolve(location.uri.toString());
        validateYlSource(YlNetworkSource(location.uri));
      } else if (location.uri.scheme != 'file' ||
          location.uri.host.isNotEmpty) {
        throw subtitleFailure(YlFailureCodes.subtitleUnsupported);
      }
    }
    _busy = true;
    final owned = SubtitleCancellation();
    final remove = token.listen(owned.cancel);
    try {
      final operation = source is YlFileSource
          ? _file(resource, owned, maxBytes)
          : _http(resource, owned, maxBytes);
      return await (source is YlNetworkSource &&
              (source as YlNetworkSource).networkPolicy.kind ==
                  YlNetworkPolicyKind.managed
          ? operation
          : operation.timeout(
              const Duration(seconds: 30),
              onTimeout: () {
                owned.cancel();
                throw subtitleFailure(YlFailureCodes.networkFailed);
              },
            ));
    } catch (error) {
      token.check();
      if (error is YlPlayerException) rethrow;
      throw subtitleFailure(
        source is YlFileSource
            ? YlFailureCodes.sourceInvalid
            : YlFailureCodes.networkFailed,
      );
    } finally {
      remove();
      owned.cancel();
      _busy = false;
    }
  }

  void _attempt() {
    if (++_attempts > 4096) {
      throw subtitleFailure(YlFailureCodes.subtitleTooLarge);
    }
  }

  void _progress(int bytes) {
    if (bytes > 64 * 1024 * 1024 - _received) {
      throw subtitleFailure(YlFailureCodes.subtitleTooLarge);
    }
    _received += bytes;
  }

  Future<DashSubtitleReply> _http(
    DashSubtitleResource resource,
    SubtitleCancellation token,
    int maxBytes,
  ) async {
    final key = resource.key;
    var ledger = _histories[key];
    if (ledger == null) {
      if (_histories.length >= 4096 ||
          key.length > 4 * 1024 * 1024 - _uriUnits) {
        throw subtitleFailure(YlFailureCodes.subtitleTooLarge);
      }
      _uriUnits += key.length;
      ledger = _NetworkLedger(
        resource.locations.first.uri,
        onAttempt: _attempt,
        onProgress: _progress,
      );
      _histories[key] = ledger;
    }
    final history = ledger;
    final original = source as YlNetworkSource;
    // Both explicit ancestry and root-origin comparison apply; a constructed
    // location with a default flag cannot accidentally grant foreign credentials.
    bool foreign(Uri uri) =>
        uri.scheme != original.uri.scheme ||
        uri.host != original.uri.host ||
        uri.port != original.uri.port;
    history.stripped |=
        resource.locations.any(
          (v) => v.uri == history.uri && v.credentialsStripped,
        ) ||
        foreign(history.uri);
    final validator = _validators[history.uri];
    final range = resource.range == null
        ? null
        : _RangeRequest(
            resource.range!.start,
            resource.range!.start + resource.range!.length - 1,
            expectedTag: validator?.$1,
            expectedTotal: validator?.$2,
          );
    var candidate = resource.locations.indexWhere((v) => v.uri == history.uri);
    final reply = await _network(
      original,
      token,
      maxBytes,
      shared: history,
      range: range,
      advanceCandidate: () {
        if (resource.locations.length == 1) return;
        if (range?.expectedTag != null) {
          throw subtitleFailure(YlFailureCodes.subtitleUnsupported);
        }
        candidate = (candidate + 1) % resource.locations.length;
        final next = resource.locations[candidate];
        history.stripped |=
            next.credentialsStripped ||
            foreign(next.uri) ||
            history.uri.scheme != next.uri.scheme ||
            history.uri.host != next.uri.host ||
            history.uri.port != next.uri.port;
        history.uri = next.uri;
      },
    );
    if (range != null) {
      _validators[history.uri] = (range.receivedTag!, range.receivedTotal!);
    }
    token.check();
    return DashSubtitleReply(
      reply.bytes!,
      DashSubtitleLocation(history.uri, credentialsStripped: history.stripped),
      sourceOffset: resource.range?.start ?? 0,
    );
  }

  Future<DashSubtitleReply> _file(
    DashSubtitleResource resource,
    SubtitleCancellation token,
    int maxBytes,
  ) async {
    _attempt();
    final location = resource.locations.first;
    final path = location.uri.toFilePath();
    if (await FileSystemEntity.type(path) != FileSystemEntityType.file) {
      throw subtitleFailure(YlFailureCodes.sourceInvalid);
    }
    token.check();
    final file = await File(path).open();
    try {
      final length = await file.length();
      final start = resource.range?.start ?? 0,
          count = resource.range?.length ?? length;
      if (count > maxBytes || start > length || count > length - start) {
        throw subtitleFailure(YlFailureCodes.subtitleTooLarge);
      }
      await file.setPosition(start);
      token.check();
      final bytes = await file.read(count);
      token.check();
      if (bytes.length != count) {
        throw subtitleFailure(YlFailureCodes.sourceInvalid);
      }
      _progress(count);
      return DashSubtitleReply(bytes, location, sourceOffset: start);
    } finally {
      await file.close();
    }
  }
}
