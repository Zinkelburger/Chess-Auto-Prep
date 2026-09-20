import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The `[LineID]` a game written for [sans] at file position [index] gets.
///
/// It is the id the old app derives for a game that carries no id header —
/// base64url of `"<moves>|<index>"`, truncated to 22 characters after
/// `line_` — so both apps name the same line the same way and the training
/// progress keyed by that name keeps pointing at it.
///
/// Truncation is not collision-free, and two lines sharing one id mix their
/// review histories and let a delete land on the wrong game. An id already
/// in [taken] is therefore replaced by the SHA-256 of the same key, which
/// no shared opening prefix can collide.
String newLineId(List<String> sans, int index, Set<String> taken) {
  final key = '${sans.join(' ')}|$index';
  final encoded = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
  final short = encoded.length > 22 ? encoded.substring(0, 22) : encoded;
  if (!taken.contains('line_$short')) return 'line_$short';
  var id = _hashed(key);
  while (taken.contains(id)) {
    id = _hashed('$key|$id');
  }
  return id;
}

String _hashed(String key) =>
    'line_${sha256.convert(utf8.encode(key)).toString().substring(0, 22)}';
