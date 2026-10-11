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

Future<void> _request(HttpClient client, Map<String, String> config) async {
  final request = await client.headUrl(Uri.parse(config['url']!));
  request.followRedirects = false;
  final response = await request.close();
  final expected = {
    'X-Yl-Run-Id': config['runId'],
    'X-Yl-Profile-Id': config['profileId'],
    'X-Yl-Profile-Sha256': config['profileHash'],
    'X-Yl-Asset-Sha256': config['mediaHash'],
    'X-Yl-Timeline-Mode': 'first-get',
    'X-Yl-Timeline-State': 'pending',
  };
  if (response.statusCode != 200 ||
      expected.entries.any((e) => response.headers.value(e.key) != e.value)) {
    throw StateError('Owned server identity mismatch');
  }
  await response.drain<void>();
}
