part of 'dash_subtitles.dart';

/// Rational programme time, reduced and checked before native Duration output.
/// Never accumulate rounded microseconds across Periods or repeated seeks.
final class DashSubtitleTime implements Comparable<DashSubtitleTime> {
  DashSubtitleTime._(this.numerator, this.denominator);
  final BigInt numerator, denominator;
  static final _max = BigInt.parse('9223372036854775807');
  static final zero = DashSubtitleTime.of(0);
  factory DashSubtitleTime.of(int value, [int scale = 1]) =>
      DashSubtitleTime._make(BigInt.from(value), BigInt.from(scale));
  factory DashSubtitleTime._make(BigInt n, BigInt d) {
    if (d <= BigInt.zero) _dashBad();
    final gcd = n.gcd(d);
    n ~/= gcd;
    d ~/= gcd;
    if (n < -_max - BigInt.one || n > _max || d > _max) _dashLimit();
    return DashSubtitleTime._(n, d);
  }
  DashSubtitleTime operator +(DashSubtitleTime b) => DashSubtitleTime._make(
    numerator * b.denominator + b.numerator * denominator,
    denominator * b.denominator,
  );
  DashSubtitleTime operator -(DashSubtitleTime b) => DashSubtitleTime._make(
    numerator * b.denominator - b.numerator * denominator,
    denominator * b.denominator,
  );
  @override
  int compareTo(DashSubtitleTime b) =>
      (numerator * b.denominator).compareTo(b.numerator * denominator);
  bool operator <(DashSubtitleTime b) => compareTo(b) < 0;
  bool operator <=(DashSubtitleTime b) => compareTo(b) <= 0;
  bool operator >(DashSubtitleTime b) => compareTo(b) > 0;
  bool operator >=(DashSubtitleTime b) => compareTo(b) >= 0;
  int units(int scale, {bool ceil = false}) {
    final n = numerator * BigInt.from(scale);
    var q = n ~/ denominator;
    if (n.remainder(denominator) != BigInt.zero) {
      if (ceil && n > BigInt.zero) q += BigInt.one;
      if (!ceil && n < BigInt.zero) q -= BigInt.one;
    }
    if (q < -_max - BigInt.one || q > _max) _dashLimit();
    return q.toInt();
  }

  int microseconds({bool ceil = false}) => units(1000000, ceil: ceil);
  @override
  bool operator ==(Object other) =>
      other is DashSubtitleTime &&
      numerator == other.numerator &&
      denominator == other.denominator;
  @override
  int get hashCode => Object.hash(numerator, denominator);
  @override
  String toString() => '$numerator/$denominator';
  static DashSubtitleTime parseDuration(String value) {
    if (value.length > 128) _dashLimit();
    final m = RegExp(
      r'^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)(?:\.(\d{1,18}))?S)?)?$',
    ).firstMatch(value);
    if (m == null || ![1, 2, 3, 4].any((i) => m[i] != null)) _dashBad();
    var result = zero;
    for (final (index, multiplier) in [
      (1, 86400),
      (2, 3600),
      (3, 60),
      (4, 1),
    ]) {
      if (m[index] != null) {
        result += DashSubtitleTime._make(
          BigInt.from(_dashInt(m[index]!)) * BigInt.from(multiplier),
          BigInt.one,
        );
      }
    }
    if (m[5] case final digits?) {
      result += DashSubtitleTime._make(
        BigInt.parse(digits),
        BigInt.from(10).pow(digits.length),
      );
    }
    return result;
  }
}

int _dashInt(String value, {bool signed = false}) {
  if (value.length > 20 ||
      !(signed ? RegExp(r'^-?\d+$') : RegExp(r'^\d+$')).hasMatch(value)) {
    _dashBad();
  }
  final n = BigInt.parse(value);
  if (n < -DashSubtitleTime._max || n > DashSubtitleTime._max) _dashLimit();
  return n.toInt();
}

int _dashAdd(int a, int b) => DashSubtitleTime._make(
  BigInt.from(a) + BigInt.from(b),
  BigInt.one,
).units(1);
int _dashMultiply(int a, int b) => DashSubtitleTime._make(
  BigInt.from(a) * BigInt.from(b),
  BigInt.one,
).units(1);
