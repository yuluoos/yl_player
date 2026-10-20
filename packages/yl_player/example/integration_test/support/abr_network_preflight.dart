import 'dart:async';
import 'dart:io';

Future<void> preflightAbr(
  Map<String, String> config, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    await _request(client, config).timeout(timeout);
  } finally {
    client.close(force: true);
  }
}

Future<int?> _request(
  HttpClient client,
  Map<String, String> config, {
  bool active = false,
}) async {
  final request = await client.headUrl(Uri.parse(config['url']!));
  request.followRedirects = false;
  final response = await request.close();
  final expected = {
    'X-Yl-Run-Id': config['runId'],
    'X-Yl-Profile-Id': config['profileId'],
    'X-Yl-Profile-Sha256': config['profileHash'],
    'X-Yl-Asset-Sha256': config['mediaHash'],
    'X-Yl-Timeline-Mode': 'first-get',
    'X-Yl-Timeline-State': active ? 'active' : 'pending',
  };
  if (response.statusCode != 200 ||
      expected.entries.any((e) => response.headers.value(e.key) != e.value)) {
    throw StateError('Owned server identity mismatch');
  }
  final elapsed = int.tryParse(response.headers.value('X-Yl-Elapsed-Us') ?? '');
  await response.drain<void>();
  if (active && (elapsed == null || elapsed < 0 || elapsed > 1000000000000)) {
    throw StateError('Owned server clock unavailable');
  }
  return elapsed;
}

/// Bounds the profile clock offset using a verified HEAD round trip. The
/// interval includes request/response delay; it is not an RTT measurement.
Future<Map<String, int>> alignAbrClock(
  Map<String, String> config, {
  required int Function() nowUs,
  Duration timeout = const Duration(seconds: 5),
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final before = nowUs();
    final server = await _request(
      client,
      config,
      active: true,
    ).timeout(timeout);
    final after = nowUs();
    if (before < 0 || after < before) throw StateError('Invalid local clock');
    return {'beforeUs': before, 'afterUs': after, 'serverUs': server!};
  } finally {
    client.close(force: true);
  }
}
