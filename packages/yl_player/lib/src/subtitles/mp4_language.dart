part of 'mp4_subtitles.dart';

// RFC 5646 syntax only: no registry lookup or canonicalization. Keep the
// original spelling for display; comparisons below are case insensitive.
bool _wellFormedLanguage(String tag) {
  final lower = tag.toLowerCase();
  const grandfathered = {
    'en-gb-oed',
    'i-ami',
    'i-bnn',
    'i-default',
    'i-enochian',
    'i-hak',
    'i-klingon',
    'i-lux',
    'i-mingo',
    'i-navajo',
    'i-pwn',
    'i-tao',
    'i-tay',
    'i-tsu',
    'sgn-be-fr',
    'sgn-be-nl',
    'sgn-ch-de',
    'art-lojban',
    'cel-gaulish',
    'no-bok',
    'no-nyn',
    'zh-guoyu',
    'zh-hakka',
    'zh-min',
    'zh-min-nan',
    'zh-xiang',
  };
  if (grandfathered.contains(lower)) return true;
  final parts = lower.split('-');
  final alpha = RegExp(r'^[a-z]+$');
  final alnum = RegExp(r'^[a-z0-9]{1,8}$');
  if (parts.any((p) => !alnum.hasMatch(p))) return false;
  if (parts.first == 'x') return parts.length > 1;
  final language = parts.first;
  if (language.length < 2 || !alpha.hasMatch(language)) return false;
  var at = 1;
  if (language.length <= 3) {
    var count = 0;
    while (at < parts.length &&
        count < 3 &&
        parts[at].length == 3 &&
        alpha.hasMatch(parts[at])) {
      at++;
      count++;
    }
  }
  if (at < parts.length && parts[at].length == 4 && alpha.hasMatch(parts[at])) {
    at++;
  }
  if (at < parts.length &&
      ((parts[at].length == 2 && alpha.hasMatch(parts[at])) ||
          RegExp(r'^[0-9]{3}$').hasMatch(parts[at]))) {
    at++;
  }
  final variants = <String>{};
  while (at < parts.length &&
      (parts[at].length >= 5 ||
          RegExp(r'^[0-9][a-z0-9]{3}$').hasMatch(parts[at]))) {
    if (!variants.add(parts[at++])) return false;
  }
  final singletons = <String>{};
  while (at < parts.length && parts[at].length == 1 && parts[at] != 'x') {
    if (!singletons.add(parts[at++])) return false;
    final start = at;
    while (at < parts.length && parts[at].length >= 2) {
      at++;
    }
    if (at == start) return false;
  }
  if (at < parts.length && parts[at] == 'x') return at + 1 < parts.length;
  return at == parts.length;
}
