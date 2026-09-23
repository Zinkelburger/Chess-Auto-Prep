import 'dart:async';

import 'package:dartchess/dartchess.dart' show Move;
import 'package:flutter/foundation.dart';

import '../chess/explorer_answer.dart';
import '../chess/explorer_choice.dart';
import '../chess/fen.dart';
import '../chess/pgn/game_tree.dart';
import '../chess/pgn/tree_edit.dart';
import '../diagnostics/log.dart';
import '../storage/settings_store.dart';
import 'document_session.dart';
import 'explorer_databases.dart';
import 'gap_walk.dart' show indexOfReply;

export '../chess/explorer_answer.dart' show ExplorerGame;
export '../chess/explorer_choice.dart';

/// One move of the table: what the database counted, spelled for the
/// position on the board, and whether the chapter plays it here.
final class ExplorerRow {
  const ExplorerRow({
    required this.uci,
    required this.san,
    required this.games,
    required this.share,
    required this.white,
    required this.draws,
    required this.black,
    required this.after,
    required this.inRepertoire,
  });

  final String uci;
  final String san;

  final int games;

  /// `31%`, or `<1%`.
  final String share;

  final int white;
  final int draws;
  final int black;

  /// The position it leaves behind, for the small board under the pointer.
  final Fen after;

  final bool inRepertoire;
}

sealed class ExplorerState {
  const ExplorerState();
}

/// Nothing is open.
final class ExplorerIdle extends ExplorerState {
  const ExplorerIdle();
}

/// The database has been asked and has not answered yet.
final class ExplorerAsking extends ExplorerState {
  const ExplorerAsking(this.source);

  final ExplorerSource source;
}

final class ExplorerShown extends ExplorerState {
  const ExplorerShown(this.rows, this.answer);

  /// Most played first.
  final List<ExplorerRow> rows;

  /// What the rows were made from, for the totals and the games list.
  final ExplorerAnswer answer;
}

/// The database answered and had nothing, or was not asked because it
/// would have nothing.
final class ExplorerNothing extends ExplorerState {
  const ExplorerNothing(this.sentence);

  final String sentence;
}

final class ExplorerFailed extends ExplorerState {
  const ExplorerFailed(this.sentence);

  final String sentence;
}

/// What the databases say about the position on the board.
///
/// Owns the choice of database (kept in the settings), the answers it has
/// had ([ExplorerAnswers], in memory for the session) and the state of the
/// one it is waiting for. Reads the [DocumentSession] for the position and
/// the chapter's moves; never holds a copy of either. Keeping a listed game
/// as a file is the [GameFetcher]'s.
///
/// A cursor that moves is answered from the cache at once or asked about a
/// quarter of a second after it comes to rest, so walking a line does not
/// send a request per ply. The database is not asked past move 25, nor
/// deeper on a line where three positions in a row had nothing. A fetch
/// that fails takes nothing away: what was cached stays cached, and a
/// retry that fails leaves the rows it was refreshing on the screen with
/// one line saying what went wrong.
final class Explorer extends ChangeNotifier {
  Explorer({
    required DocumentSession session,
    required SettingsStore settings,
    required ExplorerDatabases databases,
    this.debounce = const Duration(milliseconds: 250),
  }) : _session = session,
       _settings = settings,
       _databases = databases {
    _choiceNow = _settings.value.explorer;
    _session.anyChange.addListener(_followTheBoard);
    _settings.addListener(_followTheSettings);
    unawaited(_checkTheBook());
    _followTheBoard();
  }

  /// How long the cursor must rest before a database is asked.
  final Duration debounce;

  /// The deepest ply a database is asked about.
  static const deepestPly = 50;

  final DocumentSession _session;
  final SettingsStore _settings;
  final ExplorerDatabases _databases;

  final _answers = ExplorerAnswers();
  var _choiceNow = ExplorerChoice.defaults;
  ExplorerState _state = const ExplorerIdle();
  String? _notice;
  bool _twic = false;
  Timer? _rest;
  int _ticket = 0;
  ({GameTree? tree, NodePath at})? _board;
  bool _disposed = false;

  ExplorerState get state => _state;

  /// One line beside the rows: a refresh that failed while they stayed.
  String? get notice => _notice;

  ExplorerChoice get choice => _choiceNow;

  /// The databases that can be asked: TWIC only when it is on this machine.
  List<ExplorerSource> get sources => [
    ExplorerSource.masters,
    ExplorerSource.lichess,
    if (_twic) ExplorerSource.twic,
  ];

  bool get twicAvailable => _twic;

  /// How many plies deep the position on the board is.
  int get ply => plyOf(_session.fen);

  /// Changes what is asked; the settings remember it.
  void choose(ExplorerChoice choice) =>
      unawaited(_settings.update(_settings.value.copyWith(explorer: choice)));

  /// Asks again, now, whatever the cache holds: the user's `Try again`.
  Future<void> retry() async {
    _notice = null;
    final fen = _session.fen;
    if (_session.chapter == null) return;
    _answers
      ..forget(fen, _choiceNow)
      ..resetEmpties();
    await _checkTheBook();
    await _ask(fen, kept: _state is ExplorerShown ? _state : null);
  }

  Future<void> _checkTheBook() async {
    final available = await _databases.bookAvailable();
    if (_disposed || available == _twic) return;
    _twic = available;
    notifyListeners();
  }

  void _followTheSettings() {
    final choice = _settings.value.explorer;
    if (choice == _choiceNow) return;
    _choiceNow = choice;
    _answers.resetEmpties();
    _notice = null;
    _followTheSession();
  }

  /// Asks again when the board is somewhere else or the tree it marks the
  /// rows against changed; a refusal, a flip or a save leaves the rows as
  /// they are. A move just written tells this twice, cursor then chapter,
  /// and is asked about once.
  void _followTheBoard() {
    final board = (tree: _session.tree, at: _session.cursor);
    final seen = _board;
    if (seen != null &&
        identical(seen.tree, board.tree) &&
        seen.at == board.at) {
      return;
    }
    _board = board;
    _followTheSession();
  }

  void _followTheSession() {
    if (_disposed) return;
    _rest?.cancel();
    if (_session.chapter == null) {
      _show(const ExplorerIdle());
      return;
    }
    final fen = _session.fen;
    final cached = _answers.at(fen, _choiceNow);
    if (cached != null) {
      _show(_shown(fen, cached));
      return;
    }
    final ply = plyOf(fen);
    if (ply > deepestPly) {
      _show(const ExplorerNothing('The database is not asked past move 25.'));
      return;
    }
    if (_answers.pastEmpties(ply)) {
      _show(const ExplorerNothing('No games found for this position.'));
      return;
    }
    _show(ExplorerAsking(_choiceNow.source));
    // No rest is no timer: a test's clock has nothing left pending.
    if (debounce == Duration.zero) {
      unawaited(_ask(fen));
    } else {
      _rest = Timer(debounce, () => unawaited(_ask(fen)));
    }
  }

  /// Asks the chosen database about [fen]. [kept] is what stays on the
  /// screen if the answer does not come, with a line saying so.
  Future<void> _ask(Fen fen, {ExplorerState? kept}) async {
    final ticket = ++_ticket;
    final choice = _choiceNow;
    if (kept == null) _show(ExplorerAsking(choice.source));
    ExplorerAnswer? answer;
    String? problem;
    try {
      (answer, problem) = await _databases.ask(fen, choice);
    } on Object catch (error) {
      log.e('ask ${choice.source.title} about ${fen.value}', error);
      problem = 'Could not ask ${choice.source.title}.';
    }
    if (_disposed || ticket != _ticket) return;
    if (answer == null) {
      if (kept != null) {
        _notice = problem;
        _show(kept);
      } else {
        _show(ExplorerFailed(problem ?? 'Could not ask the database.'));
      }
      return;
    }
    _answers.remember(fen, choice, answer);
    if (fen != _session.fen || choice != _choiceNow) return;
    _show(_shown(fen, answer));
  }

  ExplorerState _shown(Fen fen, ExplorerAnswer answer) {
    if (answer.isEmpty) {
      return const ExplorerNothing('No games found for this position.');
    }
    final tree = _session.tree;
    final siblings = tree?.nodeAt(_session.cursor)?.children ?? tree?.children;
    final rows = <ExplorerRow>[];
    for (final move in answer.moves) {
      final parsed = Move.parse(move.uci);
      final node = parsed == null ? null : moveNode(fen, parsed);
      if (node == null) {
        log.w('read the explorer move ${move.uci} at ${fen.value}');
        continue;
      }
      rows.add(
        ExplorerRow(
          uci: move.uci,
          san: node.san,
          games: move.games,
          share: formatShare(move.games, answer.total),
          white: move.white,
          draws: move.draws,
          black: move.black,
          after: node.fen,
          inRepertoire:
              siblings != null && indexOfReply(fen, siblings, move.uci) >= 0,
        ),
      );
    }
    return ExplorerShown(List.unmodifiable(rows), answer);
  }

  void _show(ExplorerState state) {
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _rest?.cancel();
    _session.anyChange.removeListener(_followTheBoard);
    _settings.removeListener(_followTheSettings);
    super.dispose();
  }
}

/// What the databases have answered this session, and what that says about
/// asking deeper.
///
/// Answers are kept by choice and position, the oldest dropped past
/// [cacheSize]. Empty answers are counted along a line: each one deeper
/// than the last adds to the run, and after [emptiesBeforeStopping] of
/// them nothing deeper is asked — a line that left the database three
/// positions ago will not come back into it. A non-empty answer, or an
/// empty one no deeper than the last, starts the count again.
///
/// Example: empty answers at plies 8, 9 and 10 stop the asking at ply 11
/// and below; the user stepping back to ply 7 is asked about as usual.
final class ExplorerAnswers {
  /// How many answers are kept.
  static const cacheSize = 2000;

  /// How many empty answers in a row, each deeper than the last, stop the
  /// asking on that line.
  static const emptiesBeforeStopping = 3;

  final _cache = <String, ExplorerAnswer>{};
  int _emptyRun = 0;
  int _emptyPly = -1;

  ExplorerAnswer? at(Fen fen, ExplorerChoice choice) =>
      _cache[_key(fen, choice)];

  /// Keeps [answer] and counts it if it is empty.
  void remember(Fen fen, ExplorerChoice choice, ExplorerAnswer answer) {
    _cache[_key(fen, choice)] = answer;
    while (_cache.length > cacheSize) {
      _cache.remove(_cache.keys.first);
    }
    if (!answer.isEmpty) {
      _emptyRun = 0;
      return;
    }
    final ply = plyOf(fen);
    _emptyRun = ply > _emptyPly ? _emptyRun + 1 : 1;
    _emptyPly = ply;
  }

  /// Drops the answer for [fen], so the next ask goes to the database.
  void forget(Fen fen, ExplorerChoice choice) =>
      _cache.remove(_key(fen, choice));

  /// The line's empty answers no longer stop anything: the user asked again
  /// or asked another database.
  void resetEmpties() => _emptyRun = 0;

  /// Whether a position [ply] plies deep is past the empty answers on its
  /// line, and so not worth asking about.
  bool pastEmpties(int ply) =>
      _emptyRun >= emptiesBeforeStopping && ply > _emptyPly;

  String _key(Fen fen, ExplorerChoice choice) =>
      '${choice.key}|${fen.position}';
}

/// How many plies deep [fen] is: nought at the start.
int plyOf(Fen fen) => (fen.fullMove - 1) * 2 + (fen.whiteToMove ? 0 : 1);
