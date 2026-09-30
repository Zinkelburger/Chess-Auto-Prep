import 'dart:convert';
import 'package:crypto/crypto.dart';

import '../game_filter.dart';
import '../fen.dart';
import 'tree_edit.dart' show nullMoveSan, positionOf;
import 'chapter_line.dart';
import 'collection_player.dart';
import 'game_order.dart';
import 'game_text.dart';
import 'game_tree.dart';

/// Compatible with the old per-file session. v2 additionally remembers a
/// variation's path/FEN, the filter and whose side the games are shown
/// from; none of them is a source-PGN edit.
final class ReadingPlace {
  const ReadingPlace({
    required this.game,
    required this.key,
    required this.path,
    required this.sort,
    this.fen,
    this.filter = GameFilter.none,
    this.perspective = const FollowCollectionPlayer(),
  });
  final int game;
  final String key;
  final NodePath path;
  final String? fen;
  final GameOrder sort;
  final GameFilter filter;
  final Perspective perspective;
  Map<String, Object?> get json => {
    'gameIndex': game,
    'gameKey': key,
    'ply': path.indexes.takeWhile((i) => i == 0).length,
    'sort': sort.name,
    'v2Path': path.indexes,
    'v2Fen': fen,
    'v2Filter': {
      'any': filter.any,
      if (filter.position case final position?) 'position': position.value,
      'rules': [
        for (final r in filter.active)
          {'field': r.field, 'rule': r.rule.name, 'value': r.value},
      ],
    },
    if (switch (perspective) {
          FollowPlayer(:final name) => name,
          FollowNobody() => '',
          FollowCollectionPlayer() => null,
        }
        case final follow?)
      'v2Follow': follow,
  };
  static ReadingPlace? decode(String? raw) {
    try {
      final data = jsonDecode(raw ?? '');
      if (data is! Map<String, Object?> ||
          data['gameIndex'] is! int ||
          data['gameKey'] is! String)
        return null;
      final indexes = data['v2Path'];
      final ply = (data['ply'] is int ? data['ply'] as int : 0).clamp(0, 10000);
      final path =
          indexes is List &&
              indexes.length <= 10000 &&
              indexes.every((i) => i is int && i >= 0)
          ? indexes.cast<int>()
          : List.filled(ply, 0);
      return ReadingPlace(
        game: data['gameIndex'] as int,
        key: data['gameKey'] as String,
        path: NodePath.of(path),
        fen: data['v2Fen'] is String ? data['v2Fen'] as String : null,
        sort: GameOrder.values.asNameMap()[data['sort']] ?? GameOrder.fileOrder,
        filter: _filter(data['v2Filter']),
        perspective: switch (data['v2Follow']) {
          '' => const FollowNobody(),
          final String name => FollowPlayer(name),
          _ => const FollowCollectionPlayer(),
        },
      );
    } on Object {
      return null;
    }
  }

  int locate(List<ChapterLine> games) {
    if (game >= 0 && game < games.length && readingGameKey(games[game]) == key)
      return game;
    return games.indexWhere((g) => readingGameKey(g) == key);
  }
}

GameFilter _filter(Object? data) {
  if (data is! Map<String, Object?> || data['rules'] is! List)
    return GameFilter.none;
  final rules = <HeaderRule>[];
  for (final raw in (data['rules'] as List).take(100)) {
    if (raw is! Map<String, Object?> ||
        raw['field'] is! String ||
        raw['value'] is! String)
      continue;
    final rule = FilterRule.values.asNameMap()[raw['rule']];
    if (rule != null)
      rules.add(
        HeaderRule(
          field: raw['field'] as String,
          value: raw['value'] as String,
          rule: rule,
        ),
      );
  }
  final position = data['position'] is String
      ? Fen(data['position'] as String)
      : null;
  return GameFilter(
    rules: List.unmodifiable(rules),
    any: data['any'] == true,
    position: position != null && positionOf(position) != null
        ? position
        : null,
  );
}

/// Rebuilds the existing canonical identity from parsed headers/mainline.
/// Notes and sidelines never change which game a bookmark names.
String readingGameKey(ChapterLine line) {
  String? tag(String name) => tagValue(line.tags, name);
  final id = tag('GameId');
  if (id != null && id.isNotEmpty) return id;
  for (final field in ['Link', 'Site']) {
    final url = Uri.tryParse(tag(field)?.trim() ?? '');
    if (url == null || !['http', 'https'].contains(url.scheme)) continue;
    final host = url.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    if (host == 'lichess.org' &&
        RegExp(
          r'^/[a-zA-Z0-9]{8}([a-zA-Z0-9]{4})?(/(white|black))?$',
        ).hasMatch(url.path))
      return 'https://lichess.org/${url.path.substring(1, 9)}';
    if (host == 'chess.com' &&
        RegExp(r'^/game/(live|daily)/[0-9]+/?$').hasMatch(url.path))
      return 'https://www.chess.com${url.path.replaceFirst(RegExp(r'/$'), '')}';
  }
  // The old app hashes each move as the file spelled it, reading only `0-0`
  // as `O-O` and every null move as `--`, so a reading place saved by one
  // app is found by the other.
  final moves = <String>[];
  var children = line.tree?.children ?? const <MoveNode>[];
  while (children.isNotEmpty) {
    final move = children.first;
    final spelled = move.san == nullMoveSan
        ? nullMoveSan
        : move.spelling ?? move.san;
    moves.add(spelled.replaceAll('0', 'O'));
    children = children.first.children;
  }
  final identity = [
    for (final field in [
      'Event',
      'Site',
      'Round',
      'White',
      'Black',
      'FEN',
      'Variant',
      'TimeControl',
    ])
      tag(field)?.trim() ?? '',
    tag('UTCDate') ?? tag('Date') ?? '',
    tag('UTCTime') ?? tag('Time') ?? '',
    line.tree == null ? line.text.trim() : moves.join(' '),
  ];
  return 'pgn-v2:${sha256.convert(utf8.encode(jsonEncode(identity)))}';
}
