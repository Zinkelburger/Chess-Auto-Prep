import 'dart:async';

import 'package:dartchess/dartchess.dart' show Move, Side;
import 'package:flutter/foundation.dart';

import '../chess/fen.dart';
import '../chess/generation/draft_lines.dart' show expectimaxIn;
import '../chess/pgn/game_tree.dart' show GameTree;
import '../chess/pgn/move_label.dart';
import '../chess/pgn/tree_edit.dart';
import '../diagnostics/log.dart';
import '../engines/maia/move_policy.dart';
import '../storage/settings_store.dart';
import 'document_session.dart';
import 'gap_hunt.dart';
import 'gap_walk.dart' show GapWalk, indexOfReply;

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
    this.expectimax,
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

  /// What a fill said the position after this move of ours is worth, as
  /// its `[%expectimax]` token wrote it (`+0.42`), or null when no run
  /// reached it. Read from the document, never computed here.
  final String? expectimax;
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

/// The position, the numbers and the document a Replies table is for.
typedef _TableKey = ({
  Fen fen,
  int elo,
  int onceIn,
  GapWalk? walk,
  GameTree? tree,
});

/// The Replies table: what the opponent model expects at the position on
/// the board, each move marked with whether the chapter plays it, whether
/// another chapter answers it and whether it is a gap.
///
/// Asks the [ReplyModel] again when the board is on another position, the
/// rating or the floor changed, or the [GapHunt] finished a walk whose
/// reach the gap marks read; notifies only then. Never holds a copy of the
/// tree or the cursor.
final class Replies extends ChangeNotifier {
  Replies({
    required DocumentSession session,
    required ReplyModel model,
    required SettingsStore settings,
    required GapHunt gaps,
  }) : _session = session,
       _model = model,
       _settings = settings,
       _gaps = gaps {
    _session.anyChange.addListener(_follow);
    _settings.addListener(_follow);
    _gaps.addListener(_follow);
    _follow();
  }

  /// A reply rarer than this at the position on the board gets no row,
  /// unless the chapter plays it: the table is for what happens, not for
  /// every legal move.
  static const shownFrom = 0.01;

  final DocumentSession _session;
  final ReplyModel _model;
  final SettingsStore _settings;
  final GapHunt _gaps;

  RepliesState _table = const RepliesEmpty();

  /// What the table on screen was asked for.
  /// What the table on screen was worked out for. The tree is part of it:
  /// the ticks and stored values come from the document, so another game at
  /// the same position (a viewer file's next game, a study's next chapter)
  /// or an edit marks the rows again from the shares already asked.
  _TableKey? _tableFor;

  /// Bumped for every ask and on dispose: an answer that finds it moved on
  /// was overtaken.
  int _ticket = 0;

  RepliesState get table => _table;

  /// The rating the shares are predicted for.
  int get elo => _settings.value.opponentElo;

  void _follow() {
    if (_session.chapter == null) {
      if (_table is RepliesEmpty) return;
      _table = const RepliesEmpty();
      _tableFor = null;
      _ticket++;
      notifyListeners();
      return;
    }
    final s = _settings.value;
    final wanted = (
      fen: _session.fen,
      elo: s.opponentElo,
      onceIn: s.coverOnceIn,
      walk: _gaps.walk,
      tree: _session.tree,
    );
    if (wanted == _tableFor) return;
    unawaited(_retable(wanted));
  }

  /// Tells the pane before it waits, so a table for another position never
  /// stays on screen while the model is asked.
  Future<void> _retable(_TableKey wanted) async {
    final ticket = ++_ticket;
    _tableFor = wanted;
    _table = const RepliesPending();
    notifyListeners();
    final answer = await _model.answerAt(wanted.fen);
    if (ticket != _ticket) return;
    _table = switch (answer) {
      MaiaPolicy(:final shares) => _rowsOf(wanted.fen, shares),
      MaiaFailed(:final reason) => RepliesFailed(reason),
    };
    notifyListeners();
  }

  RepliesShown _rowsOf(Fen fen, Map<String, double> shares) {
    final tree = _session.tree!;
    final cursor = _session.cursor;
    final siblings = tree.nodeAt(cursor)?.children ?? tree.children;
    final ourMove = fen.whiteToMove == (_session.chapter!.side == Side.white);
    final walk = _gaps.walk;
    final reach = walk?.reach[cursor];
    final answered = walk?.elsewhere ?? const {};
    final floor = 1 / _settings.value.coverOnceIn;
    final rows = <ReplyRow>[];
    for (final MapEntry(key: uci, value: share) in shares.entries) {
      final at = indexOfReply(fen, siblings, uci);
      final played = at >= 0;
      if (share < shownFrom && !played) continue;
      final move = Move.parse(uci);
      final node = move == null ? null : moveNode(fen, move);
      if (node == null) continue;
      final elsewhere = played ? null : answered[node.fen.position];
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
          expectimax: ourMove && played
              ? expectimaxIn(siblings[at].comment)
              : null,
        ),
      );
    }
    return RepliesShown(List.unmodifiable(rows), ourMove: ourMove);
  }

  @override
  void dispose() {
    _ticket++;
    _session.anyChange.removeListener(_follow);
    _settings.removeListener(_follow);
    _gaps.removeListener(_follow);
    super.dispose();
  }
}

/// The opponent model's answers at the rating the settings name, each
/// position asked once: the Replies table and the gap walk ask about the
/// same positions, and a chapter walked once is cheap to walk again after
/// an edit.
///
/// The move counters are not part of the position the model sees, so they
/// are not part of the key. Answers stay for the session; a failure is not
/// kept, so the next ask tries again.
final class ReplyModel {
  ReplyModel({required MovePolicy policy, required SettingsStore settings})
    : _policy = policy,
      _settings = settings;

  final MovePolicy _policy;
  final SettingsStore _settings;
  final _cache = <String, Map<String, double>>{};

  /// The model's answer for [fen] at the chosen rating.
  Future<MaiaAnswer> answerAt(Fen fen) async {
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

  /// The shares at [fen], or null when the model could not say.
  Future<Map<String, double>?> sharesAt(Fen fen) async =>
      switch (await answerAt(fen)) {
        MaiaPolicy(:final shares) => shares,
        MaiaFailed() => null,
      };
}
