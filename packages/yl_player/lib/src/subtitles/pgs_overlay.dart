import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/widgets.dart';
import 'subtitle_document.dart';

/// Portable raw decoding: the synchronous API is not implemented on Skia.
Future<ui.Image> decodePgsBitmap(PgsBitmap bitmap) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bitmap.rgba);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: bitmap.width,
      height: bitmap.height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    codec = await descriptor.instantiateCodec();
    return (await codec.getNextFrame()).image;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

typedef PgsImageDecoder = Future<ui.Image> Function(PgsBitmap);

/// The queue contains only current mounted-view requests. Rapid replacement
/// coalesces queued work; at most two jobs can retain in-flight engine decodes
/// globally, even across repeated view unmount/remount cycles.
final class _PgsJob {
  _PgsJob(this.frame, this.decoder, this.complete);
  final PgsFrame frame;
  final PgsImageDecoder decoder;
  final void Function(List<ui.Image>?) complete;
  bool cancelled = false;
  static final waiting = <_PgsJob>[];
  static int running = 0;
  void start() {
    waiting.add(this);
    pump();
  }

  void cancel() {
    cancelled = true;
    waiting.remove(this);
  }

  static void pump() {
    while (running < 2 && waiting.isNotEmpty) {
      final job = waiting.removeAt(0);
      if (job.cancelled) continue;
      running++;
      unawaited(
        job.run().whenComplete(() {
          running--;
          pump();
        }),
      );
    }
  }

  Future<void> run() async {
    final images = <ui.Image>[];
    try {
      for (final bitmap in frame.bitmaps) {
        if (cancelled) return;
        images.add(await decoder(bitmap));
        if (cancelled) return;
      }
      complete(List.of(images));
      images.clear();
    } catch (_) {
      if (!cancelled) complete(null);
    } finally {
      for (final image in images) {
        image.dispose();
      }
    }
  }
}

final class PgsSubtitleOverlay extends StatefulWidget {
  const PgsSubtitleOverlay({
    required this.frame,
    this.source = const Rect.fromLTWH(0, 0, 1, 1),
    this.decoder = decodePgsBitmap,
    this.onFailure,
    super.key,
  });
  final PgsFrame frame;

  /// Sanitized failure notification for the current mounted frame only.
  /// The owning runtime isolates it from video playback and stale selections.
  final VoidCallback? onFailure;

  /// Visible fraction of the upright presentation canvas, including cover crop.
  final Rect source;
  final PgsImageDecoder decoder;
  @override
  State<PgsSubtitleOverlay> createState() => _PgsSubtitleOverlayState();
}

final class _PgsSubtitleOverlayState extends State<PgsSubtitleOverlay> {
  List<ui.Image> images = [];
  _PgsJob? pending;
  void release() {
    for (final image in images) {
      image.dispose();
    }
    images = [];
  }

  void decode() {
    pending?.cancel();
    release();
    late final _PgsJob job;
    job = _PgsJob(widget.frame, widget.decoder, (result) {
      if (!mounted || !identical(pending, job)) {
        if (result != null) {
          for (final image in result) {
            image.dispose();
          }
        }
        return;
      }
      pending = null;
      if (result == null) {
        if (widget.onFailure case final report?) {
          report();
          return;
        }
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: FlutterError('Subtitle image creation failed.'),
            library: 'yl_player',
          ),
        );
        return;
      }
      setState(() => images = result);
    });
    pending = job;
    job.start();
  }

  @override
  void initState() {
    super.initState();
    decode();
  }

  @override
  void didUpdateWidget(PgsSubtitleOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.frame, widget.frame) ||
        oldWidget.decoder != widget.decoder) {
      decode();
    }
  }

  @override
  void dispose() {
    pending?.cancel();
    release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: CustomPaint(
      painter: _PgsPainter(widget.frame, images, widget.source),
    ),
  );
}

final class _PgsPainter extends CustomPainter {
  _PgsPainter(this.frame, List<ui.Image> images, this.source)
    : images = List.unmodifiable(images);
  final PgsFrame frame;
  final List<ui.Image> images;
  final Rect source;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.scale(
      size.width / (frame.width * source.width),
      size.height / (frame.height * source.height),
    );
    canvas.translate(-source.left * frame.width, -source.top * frame.height);
    final paint = Paint()
      ..filterQuality = FilterQuality.none
      ..isAntiAlias = false;
    for (var i = 0; i < images.length; i++) {
      final b = frame.bitmaps[i];
      canvas.drawImage(
        images[i],
        Offset(b.x.toDouble(), b.y.toDouble()),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PgsPainter oldDelegate) =>
      !identical(frame, oldDelegate.frame) ||
      source != oldDelegate.source ||
      !identical(images, oldDelegate.images);
}
