import 'dart:async';

import 'package:dartchess/dartchess.dart' show Move, Side;
import 'package:flutter/foundation.dart';

import '../chess/fen.dart';
import '../chess/pgn/move_label.dart';
import '../chess/pgn/tree_edit.dart';
import '../diagnostics/log.dart';
import '../engines/maia/move_policy.dart';
import '../storage/chapter_files.dart';
import '../storage/settings_store.dart';
import 'document_session.dart';
import 'gap_walk.dart';

import 'repertoire_answers.dart';

export 'gap_walk.dart' show DeadEnd, Gap, GapWalk, MissingReply;

/// What a reply row says when the position after it is answered by another
/// line of the same chapter rather than by another chapter.
const hereLabel = 'this chapter';

/// One move the model expects at the position on the board.
final class ReplyRow {
  const ReplyRow({
    required this.uci,
    required this.san,
    required this.label,
    required this.share,
    required this.after,
    required this.inRepertoire,
    required this.gap,
    this.elsewhere,
  });

  /// Standard UCI, as the model names it.
  final String uci;

  final String san;

  /// `5.` or `5...`, what a line's first move is numbered with.
  final String label;

  /// How often a player of the chosen rating plays it here.
  final double share;

  /// The position it leaves behind, for the small board under the pointer.
  final Fen after;

  /// The chapter already plays it here.
  final bool inRepertoire;

  /// The opponent plays it often enough to need an answer, and the chapter
  /// has none: the row the user is here to fill.
  final bool gap;

  /// The chapter of the repertoire that answers the position after it,
  /// when this chapter does not play it: the answer is on another page.
  final String? elsewhere;
}

/// What the Replies table shows for the position on the board.
sealed class RepliesState {
  const RepliesState();
}

/// Nothing is open.
final class RepliesEmpty extends RepliesState {
  const RepliesEmpty();
}

/// The model has been asked and has not answered yet.
final class RepliesPending extends RepliesState {
  const RepliesPending();
}

final class RepliesShown extends RepliesState {
  const RepliesShown(this.rows, {required this.ourMove});

  /// Most likely first, the moves worth a row.
  final List<ReplyRow> rows;

  /// It is the repertoire's own side to move, so the rows are candidates
  /// for us rather than replies to prepare for.
  final bool ourMove;
}

final class RepliesFailed extends RepliesState {
  const RepliesFailed(this.reason);

  /// Plain English, from the model.
  final String reason;
}

/// The opponent model's view of the document: what they play at the
/// position on the board, and where in the whole chapter their likely
/// replies go unanswered.
///
/// Owns the model's answers (cached by position and rating, so a chapter
/// walked once is cheap to walk again after an edit), the table for the
/// cursor, the walk over the chapter and the gap the user was last taken
/// to. Reads the [DocumentSession], the [SettingsStore] and, through
/// [RepertoireAnswers], the other chapters of the repertoire, so a reply
/// another chapter answers is not called a gap here; never holds a copy of
/// the tree or the cursor.
final class Replies extends ChangeNotifier {
  Replies({
    required DocumentSession session,
    required MovePolicy policy,
    required SettingsStore settings,
    required RepertoireAnswers answers,
  }) : _session = session,
       _policy = policy,
       _settings = settings,
       _answers = answers {
    _session.addListener(_followTheSession);
    _settings.addListener(_followTheSettings);
    _followTheSession();
  }

  /// A reply rarer than this at the position on the board gets no row,
  /// unless the chapter plays it: the table is for what happens, not for
  /// every legal move.
  static const shownFrom = 0.01;

  final DocumentSession _session;
  final MovePolicy _policy;
  final SettingsStore _settings;
  final RepertoireAnswers _answers;

  final _cache = <String, Map<String, double>>{};

  /// What the rest of the repertoire answers, by position, as of the last
  /// walk: the other chapters' positions and this chapter's own, so a
  /// transposition into either is not a gap.
  var _elsewhere = const <String, String>{};
  ChapterRef? _source;
  RepliesState _table = const RepliesEmpty();
  GapWalk? _walk;
  bool _walking = false;
  Gap? _highlighted;
  int _gapIndex = -1;
  Fen? _tableFor;
  Object? _walkedChapter;
  int _tableTicket = 0;
  int _walkTicket = 0;
  int _elo = 0;
  int _onceIn = 0;
  bool _disposed = false;

  RepliesState get table => _table;

  /// The last finished walk over the open chapter, or null before the
  /// first one finishes. Stale while [walking], and says so.
  GapWalk? get walk => _walk;

  bool get walking => _walking;

  /// The rating the shares are predicted for.
  int get elo => _settings.value.opponentElo;

  /// The gap Next took the user to, until the cursor leaves it.
  Gap? get highlighted => _highlighted;

  /// A repertoire chapter is walked; a single game of a file is not, since
  /// its gaps are not anybody's to fill.
  bool get _walkable => _session.chapter != null && _session.game == null;

  /// Takes the board to the next gap, most reached first, round and round.
  /// A missing reply lands on the position before it, with the reply's row
  /// marked in the table; a dead end lands where the chapter stops.
  void nextGap() {
    final gaps = _walk?.gaps ?? const [];
    if (gaps.isEmpty) return;
    _gapIndex = (_gapIndex + 1) % gaps.length;
    final gap = gaps[_gapIndex];
    _highlighted = gap;
    _session.goTo(gap.at);
    notifyListeners();
  }

  void _followTheSettings() {
    final s = _settings.value;
    if (s.opponentElo == _elo && s.coverOnceIn == _onceIn) return;
    _elo = s.opponentElo;
    _onceIn = s.coverOnceIn;
    _tableFor = null;
    _walkedChapter = null;
    _followTheSession();
  }

  void _followTheSession() {
    if (_disposed) return;
    final chapter = _session.chapter;
    if (chapter == null) {
      _clear();
      return;
    }
    if (_highlighted != null && _session.cursor != _highlighted!.at) {
      _highlighted = null;
    }
    if (_session.source != _source) {
      // The chapter that was open may have been edited; what it answers is
      // read again the next time another chapter is walked.
      _source = _session.source;
      _answers.forget();
    }
    if (!identical(chapter, _walkedChapter)) {
      _walkedChapter = chapter;
      unawaited(_rewalk());
    }
    if (_session.fen != _tableFor) unawaited(_retable());
    notifyListeners();
  }

  void _clear() {
    _table = const RepliesEmpty();
    _walk = null;
    _walking = false;
    _highlighted = null;
    _gapIndex = -1;
    _tableFor = null;
    _walkedChapter = null;
    _tableTicket++;
    _walkTicket++;
    notifyListeners();
  }

  Future<void> _retable() async {
    final ticket = ++_tableTicket;
    final fen = _session.fen;
    _tableFor = fen;
    _table = const RepliesPending();
    notifyListeners();
    final answer = await _asked(fen);
    if (_disposed || ticket != _tableTicket) return;
    _table = switch (answer) {
      MaiaPolicy(:final shares) => _rowsOf(fen, shares),
      MaiaFailed(:final reason) => RepliesFailed(reason),
    };
    notifyListeners();
  }

  Future<void> _rewalk() async {
    final ticket = ++_walkTicket;
    if (!_walkable) {
      _walk = null;
      _walking = false;
      return;
    }
    final chapter = _session.chapter!;
    final source = _session.source;
    _walking = true;
    final floor = 1 / _settings.value.coverOnceIn;
    final elsewhere = {
      if (source != null) ...await _answers.around(source, chapter.side),
      for (final position in answeredPositions(chapter.tree, chapter.side))
        position: hereLabel,
    };
    if (_disposed || ticket != _walkTicket) return;
    final walk = await walkGaps(
      tree: chapter.tree,
      side: chapter.side,
      floor: floor,
      shares: _sharesFor,
      overtaken: () => _disposed || ticket != _walkTicket,
      elsewhere: elsewhere,
    );
    if (_disposed || ticket != _walkTicket || walk == null) return;
    _elsewhere = elsewhere;
    _walk = walk;
    _walking = false;
    _gapIndex = -1;
    // The table's gap marks read the reach the walk just found.
    _tableFor = null;
    _followTheSession();
  }

  Future<Map<String, double>?> _sharesFor(Fen fen) async =>
      switch (await _asked(fen)) {
        MaiaPolicy(:final shares) => shares,
        MaiaFailed() => null,
      };

  /// The model's answer for [fen] at the chosen rating, from the cache when
  /// it has been asked before. The counters are not part of the position
  /// the model sees, so they are not part of the key.
  Future<MaiaAnswer> _asked(Fen fen) async {
    final elo = _settings.value.opponentElo;
    final key = '${fen.position}|$elo';
    final cached = _cache[key];
    if (cached != null) return MaiaPolicy(cached);
    final answer = await _policy.policy(fen, elo);
    if (answer case MaiaPolicy(:final shares)) _cache[key] = shares;
    if (answer case MaiaFailed(:final reason)) {
      log.w('predict replies at ${fen.value}', reason);
    }
    return answer;
  }

  RepliesShown _rowsOf(Fen fen, Map<String, double> shares) {
    final tree = _session.tree!;
    final cursor = _session.cursor;
    final siblings = tree.nodeAt(cursor)?.children ?? tree.children;
    final ourMove = fen.whiteToMove == (_session.chapter!.side == Side.white);
    final reach = _walk?.reach[cursor];
    final floor = 1 / _settings.value.coverOnceIn;
    final rows = <ReplyRow>[];
    for (final MapEntry(key: uci, value: share) in shares.entries) {
      final played = indexOfReply(fen, siblings, uci) >= 0;
      if (share < shownFrom && !played) continue;
      final move = Move.parse(uci);
      final node = move == null ? null : moveNode(fen, move);
      if (node == null) continue;
      final elsewhere = played ? null : _elsewhere[node.fen.position];
      rows.add(
        ReplyRow(
          uci: uci,
          san: node.san,
          label: moveNumberLabel(node, startsLine: true),
          share: share,
          after: node.fen,
          inRepertoire: played,
          gap:
              !ourMove &&
              !played &&
              elsewhere == null &&
              reach != null &&
              reach * share >= floor,
          elsewhere: ourMove ? null : elsewhere,
        ),
      );
    }
    return RepliesShown(List.unmodifiable(rows), ourMove: ourMove);
  }

  @override
  void dispose() {
    _disposed = true;
    _session.removeListener(_followTheSession);
    _settings.removeListener(_followTheSettings);
    super.dispose();
  }
}
