import 'dart:isolate';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:crypto/crypto.dart';
import 'dart:convert';

import '../../chess/fen.dart';
import '../../chess/opening_index.dart';
import '../../chess/pgn/game_text.dart';
import '../../chess/pgn/chapter.dart' show readOffThreadFrom;
import '../../chess/pgn/game_tree.dart';
import '../../chess/pgn/pgn_reader.dart';
import '../../chess/tactics/game_ids.dart';
import '../../storage/document_ref.dart';
import '../../chess/players/player.dart';

final class PlayerGame {
  const PlayerGame({
    required this.file,
    required this.index,
    required this.text,
  });
  final DocumentRef file;
  final int index;
  final String text;
}

final class AnalyzedGame {
  const AnalyzedGame(this.source, this.tags, this.side, this.result);
  final PlayerGame source;
  final List<PgnHeader> tags;
  final Side side;
  final String result;
  String tag(String key) => tagValue(tags, key) ?? '';
  String get title => '${tag('White')} – ${tag('Black')}';
  String get date => tag('UTCDate').isEmpty ? tag('Date') : tag('UTCDate');
  String get search =>
      '$title $date ${tag('Event')} ${tag('ECO')} ${tag('Opening')}'
          .toLowerCase();
}

final class PlayerPosition {
  PlayerPosition({
    required this.fen,
    required this.side,
    required this.line,
    required this.game,
    required this.ply,
  });
  final Fen fen;
  final Side side;
  final List<String> line;
  final int game;
  final int ply;
  final Set<int> games = {};
  final Map<String, int> moves = {};
  int wins = 0, draws = 0, losses = 0, unknown = 0;
  int get count => games.length;
  double? get score => wins + draws + losses == 0
      ? null
      : (wins + draws / 2) / (wins + draws + losses);
  String get key => '${side.name}:${fen.position}';
  String get label => line.isEmpty
      ? 'Starting position'
      : [
          for (final (i, move) in line.indexed)
            '${i.isEven ? '${i ~/ 2 + 1}. ' : ''}$move',
        ].join(' ');
}

final class PlayerCorpus {
  const PlayerCorpus(
    this.games,
    this.positions,
    this.openings, {
    required this.unmatched,
    required this.unread,
  });
  final List<AnalyzedGame> games;
  final OpeningIndex openings;
  final List<PlayerPosition> positions;
  final int unmatched, unread;
}

Future<PlayerCorpus> analyzePlayerGames(Player player, List<PlayerGame> games) {
  final names = player.names
      .map((s) => s.trim().toLowerCase())
      .where((s) => s.isNotEmpty)
      .toSet();
  if (games.fold<int>(0, (n, g) => n + g.text.length) < readOffThreadFrom)
    return Future.value(buildPlayerCorpus(names, games));
  return Isolate.run(() => buildPlayerCorpus(names, games));
}

/// Count each game once at a position, even after repetition or transposition.
/// Unmatched identities are excluded, never attributed to both colours.
PlayerCorpus buildPlayerCorpus(Set<String> names, List<PlayerGame> sources) {
  final games = <AnalyzedGame>[];
  final positions = <String, PlayerPosition>{};
  final seen = <String>{};
  var unmatched = 0, unread = 0;
  for (final source in sources) {
    final read = readGame(source.text);
    final tree = read.tree;
    if (tree == null || tree.isEmpty || !isStandardChess(read.tags)) {
      unread++;
      continue;
    }
    final side =
        names.contains(tagValue(read.tags, 'White')?.trim().toLowerCase())
        ? Side.white
        : names.contains(tagValue(read.tags, 'Black')?.trim().toLowerCase())
        ? Side.black
        : null;
    if (side == null) {
      unmatched++;
      continue;
    }
    final id = gameIdIn(source.text);
    final fallback = [
      for (final key in ['White', 'Black', 'Date', 'Round', 'Result'])
        tagValue(read.tags, key),
      _moves(tree).join(' '),
    ].join('|');
    if (!seen.add(
      id.isEmpty ? sha256.convert(utf8.encode(fallback)).toString() : id,
    ))
      continue;
    final result = tagValue(read.tags, 'Result') ?? read.terminator ?? '*';
    final index = games.length;
    games.add(AnalyzedGame(source, read.tags, side, result));
    var fen = tree.rootFen;
    MoveNode? node = tree.children.firstOrNull;
    final line = <String>[];
    final visited = <String>{};
    for (var ply = 0; ply <= 40; ply++) {
      final key = '${side.name}:${fen.position}';
      if (visited.add(key)) {
        final at = positions.putIfAbsent(
          key,
          () => PlayerPosition(
            fen: fen,
            side: side,
            line: List.of(line),
            game: index,
            ply: ply,
          ),
        );
        _count(at, index, node?.uci, result);
      }
      if (node == null) break;
      line.add(node.san);
      fen = node.fen;
      node = node.children.firstOrNull;
    }
  }
  return PlayerCorpus(
    games,
    positions.values.toList(),
    OpeningIndex.of(games.map((g) => g.source.text).toList()),
    unmatched: unmatched,
    unread: unread,
  );
}

Iterable<String> _moves(GameTree tree) sync* {
  MoveNode? node = tree.children.firstOrNull;
  while (node != null) {
    yield node.uci;
    node = node.children.firstOrNull;
  }
}

void _count(PlayerPosition at, int index, String? uci, String result) {
  at.games.add(index);
  if (uci != null) at.moves.update(uci, (n) => n + 1, ifAbsent: () => 1);
  if (result == '1/2-1/2') {
    at.draws++;
  } else if (result == (at.side == Side.white ? '1-0' : '0-1')) {
    at.wins++;
  } else if (result == (at.side == Side.white ? '0-1' : '1-0')) {
    at.losses++;
  } else {
    at.unknown++;
  }
}
