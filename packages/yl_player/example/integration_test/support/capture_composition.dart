import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

/// Apple uses hybrid native views, which RenderRepaintBoundary cannot include.
/// The host helper captures only this example's window / named simulator.
Future<(ui.Image, double, double)> captureComposition(
  RenderRepaintBoundary boundary,
) async {
  if (defaultTargetPlatform != TargetPlatform.macOS &&
      defaultTargetPlatform != TargetPlatform.iOS) {
    return (await boundary.toImage(pixelRatio: 1), 1.0, 0.0);
  }
  const url = String.fromEnvironment('P01_CAPTURE_URL');
  if (url.isEmpty) {
    throw StateError(
      'Apple composition measurement requires the P01 window capture helper.',
    );
  }
  final uri = Uri.parse(url);
  if (uri.host != '127.0.0.1' || uri.scheme != 'http') {
    throw StateError('Capture endpoint must be the owned loopback helper.');
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw StateError('Test window capture failed.');
    }
    final bytes = BytesBuilder();
    await for (final chunk in response) {
      if (bytes.length + chunk.length > 16 * 1024 * 1024) {
        throw StateError('Capture size exceeds the test bound.');
      }
      bytes.add(chunk);
    }
    final codec = await ui.instantiateImageCodec(bytes.takeBytes());
    final ui.Image image;
    try {
      image = (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
    final scale = image.width / boundary.size.width;
    // Window capture includes the macOS title bar above Flutter's content view.
    final top = image.height - boundary.size.height * scale;
    if (top < -1 || top > 100 * scale) {
      image.dispose();
      throw StateError('Capture dimensions do not match the Flutter content.');
    }
    return (image, scale, top);
  } finally {
    client.close(force: true);
  }
}
