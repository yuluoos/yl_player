import 'dart:typed_data';

/// A VOD segment uses the shared 45 kHz manifest clock. DVD packs are remuxed
/// on demand, while Blu-ray packet ranges can be served directly from UDF.
abstract interface class IsoSegment {
  int get ticks;
  bool get discontinuity;
  Future<IsoPayload> openPayload();
}

abstract interface class IsoPayload {
  int get length;
  Stream<Uint8List> read(int start, int stop);
}
