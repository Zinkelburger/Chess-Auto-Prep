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
  final short = _shortId(sans, index);
  if (!taken.contains(short)) return short;
  var id = _hashed(key);
  while (taken.contains(id)) {
    id = _hashed('$key|$id');
  }
  return id;
}

String _hashed(String key) =>
    'line_${sha256.convert(utf8.encode(key)).toString().substring(0, 22)}';

/// The id each game of a chapter is trained under, in file order, exactly as
/// the old app assigns them, because both apps key the same progress files by
/// these ids.
///
/// A game's own id header wins; a game without one gets the short id of its
/// moves and its place in the file (see [newLineId]). The first game to claim
/// an id keeps it, so ids already in the progress files stay valid, and every
/// later claimant is given the SHA-256 id of its moves instead — straight to
/// the hash, never the short id, because the id that clashed may have been a
/// header and the short id may already be saved against another game.
///
/// [games] are the games that have moves, each with its place among all the
/// games of the file: a game nothing could read keeps its place, as it does
/// in the old app, so the games after it keep their ids.
///
/// For example two header-less games of one move each, `e4` at 0 and `e4` at
/// 1, get two different short ids; two games both tagged `[LineID "x"]` get
/// `x` and a hash.
List<String> trainingLineIds(
  List<({int index, String? header, List<String> sans})> games,
) {
  final taken = <String>{};
  return [
    for (final game in games)
      _claimed(
        game.header ?? _shortId(game.sans, game.index),
        game.sans,
        game.index,
        taken,
      ),
  ];
}

String _claimed(String id, List<String> sans, int index, Set<String> taken) {
  if (taken.add(id)) return id;
  var hashed = _fullId(sans, index);
  while (!taken.add(hashed)) {
    hashed = _fullId([...sans, hashed], index);
  }
  return hashed;
}

String _shortId(List<String> sans, int index) {
  final encoded = base64Url
      .encode(utf8.encode('${sans.join(' ')}|$index'))
      .replaceAll('=', '');
  return 'line_${encoded.length > 22 ? encoded.substring(0, 22) : encoded}';
}

String _fullId(List<String> sans, int index) =>
    _hashed('${sans.join(' ')}|$index');
