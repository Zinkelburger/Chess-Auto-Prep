import 'dart:async';

import 'package:dartchess/dartchess.dart' show Move;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../chess/explorer_answer.dart';
import '../chess/explorer_choice.dart';
import '../chess/fen.dart';
import '../chess/pgn/move_label.dart';
import '../chess/pgn/tree_edit.dart';
import '../diagnostics/log.dart';
import '../net/lichess_explorer.dart';
import '../storage/chapter_files.dart';
import '../storage/master_book.dart';
import '../storage/pgn_document_store.dart' as store;
import '../storage/settings_store.dart';
import 'document_session.dart';
import 'gap_walk.dart' show indexOfReply;

export '../chess/explorer_answer.dart' show ExplorerGame;
export '../chess/explorer_choice.dart';

/// One move of the table: what the database counted, spelled for the
/// position on the board, and whether the chapter plays it here.
final class ExplorerRow {
  const ExplorerRow({
    required this.uci,
    required this.san,
    required this.label,
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

  /// `5.` or `5...`, what a line's first move is numbered with.
  final String label;

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

sealed class GameKeep {
  const GameKeep();
}

/// The game is a file in the collections folder, to open at [ply].
final class GameKept extends GameKeep {
  const GameKept(this.ref, {required this.ply});

  final ChapterRef ref;
  final int ply;
}

final class GameNotKept extends GameKeep {
  const GameNotKept(this.sentence);

  final String sentence;
}

/// What the databases say about the position on the board.
///
/// Owns the choice of database (kept in the settings), the answers it has
/// had (by position and choice, two thousand of them, in memory for the
/// session), the state of the one it is waiting for, and the games it
/// keeps as files so the viewer can open them. Reads the [DocumentSession]
/// for the position and the chapter's moves; never holds a copy of either.
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
    required LichessExplorer lichess,
    required MasterBook book,
    required store.PgnDocumentStore documents,
    required String collections,
    this.debounce = const Duration(milliseconds: 250),
  }) : _session = session,
       _settings = settings,
       _lichess = lichess,
       _book = book,
       _documents = documents,
       _collections = collections {
    _choiceNow = _settings.value.explorer;
    _session.addListener(_followTheSession);
    _settings.addListener(_followTheSettings);
    unawaited(_checkTheBook());
    _followTheSession();
  }

  /// How long the cursor must rest before a database is asked.
  final Duration debounce;

  /// The deepest ply a database is asked about.
  static const deepestPly = 50;

  /// How many empty answers in a row, each deeper than the last, stop the
  /// asking on that line.
  static const emptiesBeforeStopping = 3;

  /// How many answers are kept.
  static const cacheSize = 2000;

  final DocumentSession _session;
  final SettingsStore _settings;
  final LichessExplorer _lichess;
  final MasterBook _book;
  final store.PgnDocumentStore _documents;

  /// The `pgn_collections` folder, absolute: where fetched games go.
  final String _collections;

  final _cache = <String, ExplorerAnswer>{};
  var _choiceNow = ExplorerChoice.defaults;
  ExplorerState _state = const ExplorerIdle();
  String? _notice;
  bool _twic = false;
  Timer? _rest;
  int _ticket = 0;
  int _emptyRun = 0;
  int _emptyPly = -1;
  String? _fetchingGame;
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

  /// The game being fetched, by id, while one is.
  String? get fetchingGame => _fetchingGame;

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
    _cache.remove(_key(fen));
    _emptyRun = 0;
    await _checkTheBook();
    await _ask(fen, kept: _state is ExplorerShown ? _state : null);
  }

  /// Fetches [game] and writes it as a file of its own in the collections
  /// folder, so the viewer can open it and keep it. A file already there
  /// is opened as it is.
  Future<GameKeep> keepGame(ExplorerGame game) async {
    final source = _choiceNow.source;
    final ply = this.ply;
    _fetchingGame = game.id;
    notifyListeners();
    final pgn = await _pgnOf(game, source);
    if (_disposed) return const GameNotKept('');
    _fetchingGame = null;
    notifyListeners();
    if (pgn == null) return const GameNotKept('Could not fetch that game.');
    final ref = ChapterRef.at(
      p.join(
        _collections,
        'explorer games',
        '${gameFileName(game, source)}.pgn',
      ),
    );
    return switch (await _documents.create(ref, pgn)) {
      store.Created() || store.Collision() => GameKept(ref, ply: ply),
      store.IoFailure(:final detail) => GameNotKept(
        'Could not keep that game: $detail',
      ),
    };
  }

  Future<String?> _pgnOf(ExplorerGame game, ExplorerSource source) =>
      source == ExplorerSource.twic
      ? _book.gamePgn(game.id)
      : _lichess.gamePgn(game.id, masters: source == ExplorerSource.masters);

  Future<void> _checkTheBook() async {
    final available = await _book.available();
    if (_disposed || available == _twic) return;
    _twic = available;
    notifyListeners();
  }

  void _followTheSettings() {
    final choice = _settings.value.explorer;
    if (choice == _choiceNow) return;
    _choiceNow = choice;
    _emptyRun = 0;
    _notice = null;
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
    final cached = _cache[_key(fen)];
    if (cached != null) {
      _show(_shown(fen, cached));
      return;
    }
    final ply = plyOf(fen);
    if (ply > deepestPly) {
      _show(const ExplorerNothing('The database is not asked past move 25.'));
      return;
    }
    if (_emptyRun >= emptiesBeforeStopping && ply > _emptyPly) {
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
      (answer, problem) = await _fetch(fen, choice);
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
    _remember(_key(fen, choice), answer);
    _countEmpties(fen, answer);
    if (fen != _session.fen || choice != _choiceNow) return;
    _show(_shown(fen, answer));
  }

  Future<(ExplorerAnswer?, String?)> _fetch(
    Fen fen,
    ExplorerChoice choice,
  ) async {
    if (choice.source == ExplorerSource.twic) {
      return switch (await _book.lookup(
        fen,
        classicalOnly: choice.classicalOnly,
      )) {
        BookFound(:final answer) => (answer, null),
        BookAbsent() => (null, 'There is no master database on this machine.'),
        BookUnreadable() => (null, 'The master database could not be read.'),
      };
    }
    return switch (await _lichess.fetch(ExplorerQuery(fen, choice))) {
      ExplorerFetched(:final answer) => (answer, null),
      ExplorerNotFetched(:final problem, :final sentence) => (
        null,
        problem == ExplorerProblem.unreachable && _twic
            ? '$sentence TWIC works offline.'
            : sentence,
      ),
    };
  }

  void _remember(String key, ExplorerAnswer answer) {
    _cache[key] = answer;
    while (_cache.length > cacheSize) {
      _cache.remove(_cache.keys.first);
    }
  }

  void _countEmpties(Fen fen, ExplorerAnswer answer) {
    if (!answer.isEmpty) {
      _emptyRun = 0;
      return;
    }
    final ply = plyOf(fen);
    _emptyRun = ply > _emptyPly ? _emptyRun + 1 : 1;
    _emptyPly = ply;
  }

  String _key(Fen fen, [ExplorerChoice? choice]) =>
      '${(choice ?? _choiceNow).key}|${fen.position}';

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
          label: moveNumberLabel(node, startsLine: true),
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
    _session.removeListener(_followTheSession);
    _settings.removeListener(_followTheSettings);
    super.dispose();
  }
}

/// How many plies deep [fen] is: nought at the start.
int plyOf(Fen fen) => (fen.fullMove - 1) * 2 + (fen.whiteToMove ? 0 : 1);

final _unsafeInAName = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

/// `Carlsen, M - Nakamura, H 2024 (masters abcd1234)`: a file name for a
/// fetched game that says who played and where it came from, and that two
/// different games cannot share.
String gameFileName(ExplorerGame game, ExplorerSource source) {
  final year = game.year == null ? '' : ' ${game.year}';
  final raw = '${game.white} - ${game.black}$year (${source.name} ${game.id})';
  final safe = raw.replaceAll(_unsafeInAName, '_').trim();
  return safe.length > 100 ? safe.substring(0, 100).trim() : safe;
}
