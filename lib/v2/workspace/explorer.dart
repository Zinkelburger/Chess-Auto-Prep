import 'dart:async';

import 'package:dartchess/dartchess.dart' show Move;
import 'package:flutter/foundation.dart';

import '../chess/explorer_answer.dart';
import '../chess/explorer_choice.dart';
import '../chess/fen.dart';
import '../chess/pgn/game_tree.dart';
import '../chess/pgn/tree_edit.dart';
import '../diagnostics/log.dart';
import '../net/lichess_explorer.dart';
import '../storage/master_book.dart';
import '../storage/settings_store.dart';
import 'document_session.dart';
import 'gap_walk.dart' show indexOfReply;
import 'local_games.dart';

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

/// The games on this machine are being read into a tree. [total] is 0
/// until it is known.
final class ExplorerReading extends ExplorerState {
  const ExplorerReading(this.done, this.total);

  final int done;
  final int total;
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
///
/// `This file` and `My games` are trees of games on this machine
/// ([LocalGames]): the first look builds one, and after that every
/// position is answered at once, with no rest, no cache and no limit on
/// empty answers, since asking costs nothing.
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
    _databases.thisFile.addListener(_followTheLocalGames);
    _databases.myGames.addListener(_followTheLocalGames);
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
    ExplorerSource.thisFile,
    ExplorerSource.myGames,
  ];

  /// What the chosen source's answers are over, when it is games on this
  /// machine: `40 games`, `12 of 40 games`. Null for the other databases.
  String? get summary => _databases.local(_choiceNow.source)?.summary;

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
    if (_databases.local(_choiceNow.source) case final games?) {
      games.forget();
      _followTheSession();
      return;
    }
    final choice = _choiceNow;
    final line = _lineHere();
    // Taken before the book is looked for, while it is still this
    // position's.
    final kept = _state is ExplorerShown ? _state : null;
    _answers
      ..forget(fen, choice)
      ..resetEmpties();
    await _checkTheBook();
    // The board moved on meanwhile, and the new position has been seen to.
    if (_disposed || fen != _session.fen || choice != _choiceNow) return;
    await _ask(fen, line, kept: kept);
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
    // A line beside the rows is about the rows it came with; what is shown
    // next says its own.
    _notice = null;
    if (_session.chapter == null) {
      _show(const ExplorerIdle());
      return;
    }
    final fen = _session.fen;
    if (_databases.local(_choiceNow.source) case final games?) {
      _showLocal(fen, games);
      return;
    }
    final cached = _answers.at(fen, _choiceNow);
    if (cached != null) {
      _show(_shown(fen, cached));
      return;
    }
    if (plyOf(fen) > deepestPly) {
      _show(const ExplorerNothing('The database is not asked past move 25.'));
      return;
    }
    final line = _lineHere();
    if (_answers.pastEmpties(line)) {
      _show(const ExplorerNothing('No games found for this position.'));
      return;
    }
    _show(ExplorerAsking(_choiceNow.source));
    // No rest is no timer: a test's clock has nothing left pending.
    if (debounce == Duration.zero) {
      unawaited(_ask(fen, line));
    } else {
      _rest = Timer(debounce, () => unawaited(_ask(fen, line)));
    }
  }

  /// How the board got where it is, from the document's root.
  ExplorerLine _lineHere() {
    final tree = _session.tree;
    return ExplorerLine(tree?.rootFen ?? _session.fen, [
      for (final move in tree?.lineTo(_session.cursor) ?? const <MoveNode>[])
        move.uci,
    ]);
  }

  /// A tree being built answers from the one it had, when it had one.
  void _showLocal(Fen fen, LocalGames games) {
    games.want();
    final state = games.state;
    // A rebuild that failed leaves the rows it had, with the failure
    // beside them and Try again.
    _notice = switch (state) {
      TreeBuilt(:final notice) => notice,
      TreeFailed(:final sentence) => sentence,
      _ => null,
    };
    if (games.answerAt(fen) case final answer?) {
      _show(_shown(fen, answer));
      return;
    }
    _show(switch (state) {
      TreeReading(:final done, :final total) => ExplorerReading(done, total),
      TreeUnbuilt() => const ExplorerReading(0, 0),
      TreeEmpty(:final sentence) => ExplorerNothing(sentence),
      TreeFailed(:final sentence) => ExplorerFailed(sentence),
      TreeBuilt() => const ExplorerNothing('No games found for this position.'),
    });
  }

  /// A local tree was built, rebuilt or narrowed: the table follows when it
  /// is the one on show.
  void _followTheLocalGames() {
    if (_choiceNow.source.local) _followTheSession();
  }

  /// Asks the chosen database about [fen], reached by [line]; the games on
  /// this machine are answered by [_showLocal] and never come here. [kept]
  /// is what stays on the screen if the answer does not come, with a line
  /// saying so.
  Future<void> _ask(Fen fen, ExplorerLine line, {ExplorerState? kept}) async {
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
    if (answer != null) _answers.remember(fen, choice, answer, line);
    // The board has moved on, or another database was chosen: what is on
    // the screen now is about somewhere else, and a failure here is not.
    if (fen != _session.fen || choice != _choiceNow) return;
    if (answer == null) {
      if (kept != null) {
        _notice = problem;
        _show(kept);
      } else {
        _show(ExplorerFailed(problem ?? 'Could not ask the database.'));
      }
      return;
    }
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
    _databases.thisFile.removeListener(_followTheLocalGames);
    _databases.myGames.removeListener(_followTheLocalGames);
    super.dispose();
  }
}

/// How the board got to a position: the document's root and the moves from
/// it, as UCI. Two positions as deep as each other on different branches
/// are on different lines, which is what the empty answers are counted by.
final class ExplorerLine {
  ExplorerLine(this.root, Iterable<String> moves)
    : moves = List.unmodifiable(moves);

  final Fen root;
  final List<String> moves;

  /// Whether this line goes on past the end of [other]: the same root,
  /// [other]'s moves first, and at least one more.
  bool continues(ExplorerLine other) =>
      root == other.root &&
      moves.length > other.moves.length &&
      listEquals(moves.sublist(0, other.moves.length), other.moves);
}

/// What the databases have answered this session, and what that says about
/// asking deeper.
///
/// Answers are kept by choice and position, the oldest dropped past
/// [cacheSize]. Empty answers are counted along a line: each one further
/// down the line of the last adds to the run, and after
/// [emptiesBeforeStopping] of them nothing further down that line is
/// asked — a line that left the database three positions ago will not come
/// back into it. A non-empty answer, or an empty one off that line, starts
/// the count again.
///
/// Example: empty answers at plies 8, 9 and 10 of one line stop the asking
/// at ply 11 and below on it; the user stepping back to ply 7, or into
/// another branch however deep, is asked about as usual.
final class ExplorerAnswers {
  /// How many answers are kept.
  static const cacheSize = 2000;

  /// How many empty answers in a row, each deeper than the last, stop the
  /// asking on that line.
  static const emptiesBeforeStopping = 3;

  final _cache = <String, ExplorerAnswer>{};
  int _emptyRun = 0;
  ExplorerLine? _emptyLine;

  ExplorerAnswer? at(Fen fen, ExplorerChoice choice) =>
      _cache[_key(fen, choice)];

  /// Keeps [answer] and counts it if it is empty. [line] is how the board
  /// got to [fen].
  void remember(
    Fen fen,
    ExplorerChoice choice,
    ExplorerAnswer answer,
    ExplorerLine line,
  ) {
    _cache[_key(fen, choice)] = answer;
    while (_cache.length > cacheSize) {
      _cache.remove(_cache.keys.first);
    }
    if (!answer.isEmpty) {
      _emptyRun = 0;
      return;
    }
    _emptyRun = _goesOn(line) ? _emptyRun + 1 : 1;
    _emptyLine = line;
  }

  /// Drops the answer for [fen], so the next ask goes to the database.
  void forget(Fen fen, ExplorerChoice choice) =>
      _cache.remove(_key(fen, choice));

  /// The line's empty answers no longer stop anything: the user asked again
  /// or asked another database.
  void resetEmpties() => _emptyRun = 0;

  /// Whether the position [line] reaches is past the empty answers on it,
  /// and so not worth asking about.
  bool pastEmpties(ExplorerLine line) =>
      _emptyRun >= emptiesBeforeStopping && _goesOn(line);

  bool _goesOn(ExplorerLine line) {
    final last = _emptyLine;
    return last != null && line.continues(last);
  }

  String _key(Fen fen, ExplorerChoice choice) =>
      '${choice.key}|${fen.position}';
}

/// How many plies deep [fen] is: nought at the start.
int plyOf(Fen fen) => (fen.fullMove - 1) * 2 + (fen.whiteToMove ? 0 : 1);

/// The databases the explorer can ask: Lichess's two over the network, the
/// master book (TWIC) on this machine, and the two trees built from games
/// on this machine — the open file's and the user's own. Says how to reach
/// each one for a position or for one game's moves, and puts what went
/// wrong in a sentence; the network and the book hold nothing between
/// asks.
final class ExplorerDatabases {
  const ExplorerDatabases({
    required LichessExplorer lichess,
    required MasterBook book,
    required this.thisFile,
    required this.myGames,
  }) : _lichess = lichess,
       _book = book;

  final LichessExplorer _lichess;
  final MasterBook _book;

  /// `This file`: the open document's games ([FileTree]).
  final LocalGames thisFile;

  /// `My games`: the user's saved games ([MyGamesTree]).
  final SavedGames myGames;

  /// The tree [source] is answered from, when it is one on this machine.
  LocalGames? local(ExplorerSource source) => switch (source) {
    ExplorerSource.thisFile => thisFile,
    ExplorerSource.myGames => myGames,
    _ => null,
  };

  /// Whether the master book is on this machine.
  Future<bool> bookAvailable() => _book.available();

  /// What [choice] says about [fen], or the sentence saying why there is
  /// no answer: the online databases and TWIC, not the trees on this
  /// machine. A network failure names TWIC when the book is here.
  Future<(ExplorerAnswer?, String?)> ask(Fen fen, ExplorerChoice choice) async {
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
    switch (await _lichess.fetch(ExplorerQuery(fen, choice))) {
      case ExplorerFetched(:final answer):
        return (answer, null);
      case ExplorerNotFetched(:final problem, :final sentence):
        final offline =
            problem == ExplorerProblem.unreachable && await _book.available();
        return (null, offline ? '$sentence TWIC works offline.' : sentence);
    }
  }

  /// The PGN of [game] from the database that listed it, or null when it
  /// could not be had. A game of `This file` is already open, and is not
  /// fetched.
  Future<String?> gamePgn(ExplorerGame game, ExplorerSource source) async =>
      switch (source) {
        ExplorerSource.twic => _book.gamePgn(game.id),
        ExplorerSource.masters || ExplorerSource.lichess => _lichess.gamePgn(
          game.id,
          masters: source == ExplorerSource.masters,
        ),
        ExplorerSource.myGames => myGames.gamePgn(game.id),
        ExplorerSource.thisFile => null,
      };
}
