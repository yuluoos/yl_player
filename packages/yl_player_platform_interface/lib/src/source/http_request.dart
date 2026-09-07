import 'dart:collection';

import '../model/value_helpers.dart';

/// Request metadata with explicitly scoped credentials.
///
/// Ordinary headers may follow cross-origin media resources. Credentials may
/// only be sent to the source origin and must stay stripped after an
/// origin-changing redirect, including retries and child resources. Put custom
/// credential-bearing values in [credentials] even if their names look ordinary.
/// Validation conservatively requires any name containing auth, cookie, token,
/// key, secret or credential (ignoring case) to use [credentials]. This includes
/// compact names such as XApiKey and XAuthToken, and may also classify unrelated
/// names containing those substrings. It does not infer sensitivity from values.
final class YlHttpRequest {
  YlHttpRequest({
    Map<String, String> headers = const {},
    Map<String, String> credentials = const {},
  }) : headers = UnmodifiableMapView(Map<String, String>.of(headers)),
       credentials = UnmodifiableMapView(Map<String, String>.of(credentials));

  final Map<String, String> headers;
  final Map<String, String> credentials;

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        _headersEqual(headers, other.headers) &&
        _headersEqual(credentials, other.credentials),
  );

  @override
  int get hashCode => Object.hash(
    YlHttpRequest,
    _headersHash(headers),
    _headersHash(credentials),
  );

  @override
  String toString() => 'YlHttpRequest(<redacted>)';
}

// Preserve every entry, even in an invalid request with case collisions, so
// equality and hashing remain symmetric before boundary validation is called.
List<MapEntry<String, String>> _sortedHeaders(Map<String, String> headers) =>
    headers.entries
        .map((entry) => MapEntry(entry.key.toLowerCase(), entry.value))
        .toList()
      ..sort((a, b) {
        final keyOrder = a.key.compareTo(b.key);
        return keyOrder != 0 ? keyOrder : a.value.compareTo(b.value);
      });

bool _headersEqual(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  final left = _sortedHeaders(a);
  final right = _sortedHeaders(b);
  for (var index = 0; index < left.length; index++) {
    if (left[index].key != right[index].key ||
        left[index].value != right[index].value) {
      return false;
    }
  }
  return true;
}

int _headersHash(Map<String, String> headers) => Object.hashAll(
  _sortedHeaders(headers).map((entry) => Object.hash(entry.key, entry.value)),
);
