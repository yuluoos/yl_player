part of 'subtitle_resource_io.dart';

/// Internal HTTP random-access reader: one immutable representation per scan.
/// 16 KiB windows, <= 2 MiB LRU, <=64 MiB received bodies including retries and
/// <=4096 HTTP attempts (redirects/retries included). No full-body fallback.
final class SubtitleRangeReader {
  SubtitleRangeReader._(this.source, this.token)
    : _ledger = _NetworkLedger(source.uri, rangeScan: true);
  final YlNetworkSource source;
  final SubtitleCancellation token;
  final _NetworkLedger _ledger;
  final _cache = <int, List<int>>{};
  static const _window = 16 * 1024, _capacity = 128;
  int? _length;
  String? _tag;
  int get length => _length!;

  static Future<SubtitleRangeReader> open(
    YlNetworkSource source,
    SubtitleCancellation token,
  ) async {
    validateYlSource(source);
    for (final entry in [
      ...source.request.headers.entries,
      ...source.request.credentials.entries,
    ]) {
      final name = entry.key.toLowerCase();
      if ([
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
    final result = SubtitleRangeReader._(source, token);
    await result._block(0);
    return result;
  }

  Future<List<int>> _block(int index) async {
    token.check();
    final cached = _cache.remove(index);
    if (cached != null) {
      _cache[index] = cached;
      return cached;
    }
    final start = index * _window;
    final end = _length == null
        ? start + _window - 1
        : (start + _window - 1).clamp(0, length - 1);
    final range = _RangeRequest(
      start,
      end,
      expectedTag: _tag,
      expectedTotal: _length,
    );
    final reply = await _network(
      source,
      token,
      _window,
      shared: _ledger,
      range: range,
    );
    token.check();
    _length = range.receivedTotal;
    _tag = range.receivedTag;
    if (_cache.length >= _capacity) _cache.remove(_cache.keys.first);
    _cache[index] = reply.bytes!;
    return reply.bytes!;
  }

  Future<List<int>> read(int offset, int count) async {
    token.check();
    if (offset < 0 ||
        count < 0 ||
        count > 256 * 1024 ||
        offset > length ||
        count > length - offset) {
      throw subtitleFailure(YlFailureCodes.subtitleMalformed);
    }
    final result = BytesBuilder(copy: false);
    var at = offset;
    while (at < offset + count) {
      final block = await _block(at ~/ _window);
      final within = at % _window;
      final amount = (offset + count - at).clamp(0, block.length - within);
      result.add(block.sublist(within, within + amount));
      at += amount;
    }
    return result.takeBytes();
  }

  void clear() => _cache.clear();
}

final class _RangeRequest {
  _RangeRequest(this.start, this.end, {this.expectedTag, this.expectedTotal});
  final int start, end;
  final String? expectedTag;
  final int? expectedTotal;
  int? receivedLength, receivedTotal;
  String? receivedTag;
  Never _reject() => throw subtitleFailure(YlFailureCodes.subtitleUnsupported);
  void accept(HttpClientResponse response) {
    if (response.headers.contentType?.primaryType.toLowerCase() ==
        'multipart') {
      _reject();
    }
    final value = response.headers.value('content-range');
    final match = value == null || value.length > 100
        ? null
        : RegExp(r'^bytes (\d{1,16})-(\d{1,16})/(\d{1,16})$').firstMatch(value);
    if (match == null) _reject();
    final first = int.parse(match[1]!),
        last = int.parse(match[2]!),
        total = int.parse(match[3]!);
    if (total < 1 ||
        total > 0x1fffffffffffff ||
        first != start ||
        last != end.clamp(0, total - 1) ||
        last < first ||
        (expectedTotal != null && expectedTotal != total)) {
      _reject();
    }
    final tag = response.headers.value('etag');
    if (tag == null ||
        tag.length > 1024 ||
        !RegExp(r'^"[\x21\x23-\x7e\x80-\xff]*"$').hasMatch(tag) ||
        (expectedTag != null && expectedTag != tag)) {
      _reject();
    }
    final size = last - first + 1;
    if (response.contentLength != -1 && response.contentLength != size) {
      _reject();
    }
    receivedLength = size;
    receivedTotal = total;
    receivedTag = tag;
  }
}
