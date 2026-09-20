import 'dart:async';
import 'dart:math' as math;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../../../core/board_editor_controller.dart'
    show EditorTool, EraserTool, PieceBrush, PointerTool;
import '../../../models/board_annotation.dart';
import '../../../utils/safe_change_notifier.dart';
import '../models/bughouse_analysis.dart';
import '../models/bughouse_engine_settings.dart';
import '../models/bughouse_eval.dart';
import '../models/bughouse_history.dart';
import '../models/bughouse_notation.dart';
import '../models/bughouse_state.dart';
import '../services/bughouse_book.dart';
import '../services/bughouse_bundle.dart';
import '../services/bughouse_engine.dart';
import '../services/bughouse_engine_report.dart';
import '../services/bughouse_engine_session.dart';
import 'bughouse_tournament_controller.dart';

/// What the side panel is showing, and therefore what the boards are for.
///
/// [play] is the pane's resting state — the engine thinks about the position
/// on the boards. [setup] edits that position. [tournament] hands the engine
/// to a match instead, and the boards become the game being played: the
/// analysis pump has to let go for the duration, because one process answers
/// one question at a time.
enum BughouseMode { play, setup, tournament }

/// Owns the two-board position, the line played through it, and the engine.
///
/// Analysis runs by itself, the way a Lichess board analyses while you look at
/// it: while the play pane is open the engine keeps thinking about the current
/// position and the panel shows whatever it has so far. Nothing is entered by
/// hand and there is no search budget to choose.
///
/// The engine is still started lazily — loading a 54 MB network costs a second
/// or two — so the pane asks for analysis by calling [startAnalysis] when it
/// is actually on screen, rather than the controller launching Hivemind the
/// moment one is constructed.
class BughouseController extends ChangeNotifier with SafeChangeNotifier {
  BughouseController({
    BughouseAnalysisEngine? engineOverride,
    BughouseBook? bookOverride,
  }) {
    _history = BughouseHistory(BughouseState.initial());
    _session = BughouseEngineSession(
      engineOverride: engineOverride,
      onInfo: _onInfo,
      onChanged: notifyListeners,
    );
    unawaited(_loadEngineSettings());
    if (bookOverride != null) {
      _book = bookOverride;
    } else {
      unawaited(_openBook());
    }
  }

  Future<void> _loadEngineSettings() async {
    final loaded = await BughouseEngineSettings.load();
    if (isDisposed || loaded == _engineSettings) return;
    _engineSettings = loaded;
    // The process, if one is already up, is running on the defaults.
    _session.markOptionsDirty();
    notifyListeners();
  }

  // ------------------------------------------------------------- the book

  /// The FICS archive, if this machine has one built. Null is the ordinary
  /// case — see [BughouseBook.open].
  BughouseBook? _book;

  /// Whether the archive is available at all, which is what decides between
  /// showing the explorer and saying nothing about it.
  bool get hasBook => _book != null;

  BughouseBookStatus? get bookStatus => _book?.status;

  /// Whether the archive's table is open beside the boards.
  ///
  /// Shut by default: the engine is what the lab is for, and the archive is
  /// a reference you open the way Lichess opens its explorer — a book icon
  /// beside the boards, and the table appears beside them.
  bool _bookOpen = false;
  bool get bookOpen => _bookOpen && hasBook;

  void toggleBook() {
    if (!hasBook) return;
    _bookOpen = !_bookOpen;
    notifyListeners();
  }

  Future<void> _openBook() async {
    final book = await BughouseBook.open();
    if (book == null) return;
    if (isDisposed) {
      book.close();
      return;
    }
    _book = book;
    notifyListeners();
  }

  String? _bookFen;
  BughouseBookPosition? _bookPosition;

  /// What the archive played from the position on screen.
  ///
  /// Memoised on the dual FEN rather than recomputed on every mutation: the
  /// lookup is two indexed reads on a `WITHOUT ROWID` key, and hanging it off
  /// the position means no move, undo, edit or jump can forget to refresh it.
  BughouseBookPosition? get bookPosition {
    final book = _book;
    if (book == null) return null;
    final fen = state.dualFen;
    if (_bookFen == fen) return _bookPosition;
    _bookFen = fen;
    _bookPosition = book.explore(state.boardA.fen, state.boardB.fen);
    return _bookPosition;
  }

  /// Draws a book continuation on the boards, the way hovering an engine line
  /// does — same arrows, same drop markers, same owner discipline.
  void hoverBookMove(BughouseBookMove move, {required Object owner}) {
    final parsed = state.board(move.board).parseSan(move.san);
    if (parsed == null) return;
    final half = BughouseHalfMove.move(parsed.uci);
    hoverAction(
      BughouseJointMove(
        move.board == BughouseBoard.a ? half : const BughouseHalfMove.pass(),
        move.board == BughouseBoard.b ? half : const BughouseHalfMove.pass(),
      ),
      owner: owner,
    );
  }

  /// Plays a continuation from the book, the way clicking an engine line plays
  /// its first move.
  ///
  /// The SAN is re-parsed against the board on screen rather than trusted: the
  /// book is keyed by position, so a row can outlive the position that fetched
  /// it by one click.
  void playBookMove(BughouseBookMove move) {
    final parsed = state.board(move.board).parseSan(move.san);
    if (parsed == null || !_play(move.board, parsed)) {
      _fail('${move.san} is not legal here.');
    }
    notifyListeners();
  }

  // ------------------------------------------------------------- the engine

  /// The live engine and the rules for holding it — see
  /// [BughouseEngineSession]. An engine handed to the constructor is used in
  /// place of a launched one, which is how tests drive the pump, the
  /// generation invalidation and the scenario comparison without a real
  /// 54 MB process.
  late final BughouseEngineSession _session;

  /// The engine handed to the constructor, if any.
  BughouseAnalysisEngine? get engineOverride => _session.engineOverride;

  BughouseAnalysisEngine? get engine => _session.engine;
  bool get isStarting => _session.isStarting;
  bool get isReady => _session.isReady;
  String get backendLabel => _session.backendLabel;

  /// What the running engine reported about workers, threads and batch — the
  /// honest answer to "how many cores is it using", since Hivemind fixes its
  /// worker count and has no `Threads` option to offer.
  String get backendDetail => _session.backendDetail;

  late BughouseHistory _history;
  BughouseHistory get history => _history;

  BughouseState get state => _history.current;

  /// Engine output read against the position on screen.
  BughouseNotation get _notation => BughouseNotation(state);

  BughouseMode _mode = BughouseMode.play;
  BughouseMode get mode => _mode;

  /// The setup-mode tool, shared with the standard board editor so both
  /// boards edit the way every other board in the app does.
  EditorTool _tool = const PointerTool();
  EditorTool get tool => _tool;

  /// Board orientation, independent per board so either can be studied from
  /// either seat.
  final Map<BughouseBoard, bool> _flipped = {
    BughouseBoard.a: false,
    BughouseBoard.b: false,
  };

  /// Whether [which] is drawn from black's side. Defaults to "our seat":
  /// board A from the team's colour, board B from the partner's.
  bool isFlipped(BughouseBoard which) {
    final manual = _flipped[which]!;
    final natural = state.sideOn(which) == Side.black;
    return manual ? !natural : natural;
  }

  /// What a move under the pointer in the panel puts on the boards.
  ///
  /// A [ValueNotifier] rather than controller state, so that hovering redraws
  /// the two boards and nothing else: going through [notifyListeners] rebuilt
  /// the whole pane — both boards, four reserves, every shortlist row — on
  /// every pointer enter and exit, which is what made the panel feel as if
  /// something happened each time the pointer crossed a line.
  final ValueNotifier<BughouseHover?> hover = ValueNotifier(null);

  /// Lights [step] up on the boards, on behalf of [owner].
  ///
  /// The annotations are worked out here and now, against the position the
  /// ply is actually played from, because a line's third ply is not a move on
  /// the position currently on screen — parsing it there gave the wrong
  /// squares or none at all.
  void hoverStep(BughousePvStep step, {required Object owner}) {
    final notation = BughouseNotation(step.before);
    hover.value = BughouseHover(
      owner: owner,
      preview: notation.preview(step.action),
      a: notation.annotate(BughouseBoard.a, step.action, AnnotationBrush.blue),
      b: notation.annotate(BughouseBoard.b, step.action, AnnotationBrush.blue),
    );
  }

  void placeEditorPiece(BughouseBoard which, Square square, Piece piece) {
    final next = state.withPieceAt(which, square, piece);
    if (next != null) _replaceCurrent(next);
  }

  void moveEditorPiece(BughouseBoard which, Square from, Square? to) {
    final piece = state.board(which).board.pieceAt(from);
    if (piece == null || from == to) return;
    final setup = state.setupOf(which);
    var board = setup.board.removePieceAt(from);
    if (to != null) board = board.setPieceAt(to, piece);
    final position = BughouseState.tryBuild(
      Setup(
        board: board,
        pockets: setup.pockets,
        turn: setup.turn,
        castlingRights: setup.castlingRights,
        epSquare: null,
        halfmoves: setup.halfmoves,
        fullmoves: setup.fullmoves,
      ),
    );
    if (position != null) _replaceCurrent(state.withBoard(which, position));
  }

  /// Lights a joint action on the current position up. Null clears.
  void hoverAction(BughouseJointMove? action, {Object? owner}) {
    if (action == null) {
      hover.value = null;
      return;
    }
    final notation = _notation;
    hover.value = BughouseHover(
      owner: owner ?? action,
      preview: notation.preview(action),
      a: notation.annotate(BughouseBoard.a, action, AnnotationBrush.blue),
      b: notation.annotate(BughouseBoard.b, action, AnnotationBrush.blue),
    );
  }

  /// Drops the highlight, but only if [owner] is the one holding it.
  ///
  /// A row leaving the screen must not clear a highlight another row has just
  /// taken, which a bare clear did whenever the block rebuilt under the
  /// pointer.
  void clearHover(Object owner) {
    if (hover.value?.owner == owner) hover.value = null;
  }

  /// Arrows and drop markers for [which] — the engine's answer, drawn on the
  /// board instead of only spelled out beside it.
  ///
  /// Reading a joint action off a text row is the hard part of bughouse
  /// notation: two boards move at once, and half the moves are drops with no
  /// origin square to trace. So the move under the pointer wins the boards
  /// outright (blue, both halves), and with nothing hovered the boards carry
  /// the two standing answers — what our team should play (green) and what
  /// the other team is about to (red), which is the pair a player checks
  /// against each other.
  List<BoardAnnotation> annotationsFor(BughouseBoard which) {
    if (_mode != BughouseMode.play) return const [];
    final hovered = hover.value;
    if (hovered != null) return hovered.on(which);
    final notation = _notation;
    return [
      ...notation.annotate(which, ours.best, AnnotationBrush.green),
      ...notation.annotate(which, theirs.best, AnnotationBrush.red),
    ];
  }

  /// The last move played on [which], for the readout under that board.
  ///
  /// Per board rather than per line: the two boards are two games with two
  /// move numbers, so "what just happened here" is a different question on
  /// each of them and the whole-line cursor cannot answer it.
  BughousePly? lastPlyOn(BughouseBoard which) {
    final plies = _history.plies;
    for (var i = _history.cursor - 1; i >= 0; i--) {
      if (plies[i].board == which) return plies[i];
    }
    return null;
  }

  /// A pocket piece the user picked up, awaiting a destination square.
  ({BughouseBoard board, Side side, Role role})? _pendingDrop;
  ({BughouseBoard board, Side side, Role role})? get pendingDrop =>
      _pendingDrop;

  /// Whether the pump is allowed to run. Toggled by the pause button, and by
  /// leaving the play pane; it is not "is a search running right now".
  bool _analysisEnabled = true;
  bool get analysisEnabled => _analysisEnabled;

  /// Whether the pane is the one on screen.
  ///
  /// Mode views live in an `IndexedStack` and are built once for the life of
  /// the app, so leaving Bughouse Lab neither disposes this controller nor
  /// changes [_mode]. Without this flag the pump kept alternating 30-second
  /// passes over both teams for the rest of the session — measured at about
  /// seven cores, indefinitely, in a mode the user had left.
  bool _onScreen = true;

  /// Which team the engine is thinking about this instant, null between
  /// passes. Both teams are searched in turn, so this is what the spinner
  /// should follow rather than a single "is searching" flag.
  Side? _thinkingFor;
  Side? get thinkingFor => _thinkingFor;
  bool get isThinking => _thinkingFor != null;

  /// The generation [_thinkingFor] belongs to.
  ///
  /// `info` lines keep arriving for a couple of hundred milliseconds after a
  /// `stop`, so a move played mid-pass used to have the dying search's last
  /// line folded into the freshly cleared analysis — and since the team it was
  /// filed under might now have nothing to move, the panel showed a live score
  /// for our team directly above the words "nothing to move". A finished
  /// search is already dropped by generation; this is the same check for the
  /// lines that stream out of one.
  int _thinkingGeneration = -1;

  /// True while a scenario comparison has the engine to itself.
  bool _comparing = false;
  bool get isComparing => _comparing;

  /// A search in flight belongs to the generation it was started in. Anything
  /// that changes the position or the rules bumps this, so a result that
  /// arrives late is dropped instead of describing a position that is gone.
  int _generation = 0;

  bool _pumping = false;

  String? _error;
  String? get error => _error;

  /// The full diagnostic behind [error], when the failure came with one.
  ///
  /// Kept apart from [error] because the banner wants one sentence and a bug
  /// report wants the file sizes, the command line, the library resolution
  /// table and the engine's own stderr. The panel shows the first and offers
  /// to copy the second.
  String? _errorReport;
  String? get errorReport => _errorReport;

  /// Something the user can install to fix the current error, when the failure
  /// named one. Null for every failure installing it would not help.
  String? _errorLink;
  String? get errorLink => _errorLink;

  String? _notice;
  String? get notice => _notice;

  /// What each team currently thinks, keyed by the colour it plays on board A.
  ///
  /// Both are kept because both are questions a player has. Ours holds our own
  /// move and our partner's; theirs holds the two moves we are about to face —
  /// and it is the only thing there is to show in a position where the whole
  /// opposing team is on move and we are not.
  Map<Side, BughouseTeamAnalysis> _analyses = const {};

  BughouseTeamAnalysis get ours => _analysisFor(state.team);
  BughouseTeamAnalysis get theirs => _analysisFor(state.team.opposite);

  BughouseTeamAnalysis _analysisFor(Side team) =>
      _analyses[team] ?? BughouseTeamAnalysis(team: team);

  /// The top line of our own search — what the eval reads.
  BughouseInfo? get latest => ours.latest;

  /// Our team's best joint action.
  BughouseJointMove? get best => ours.best;

  /// Our team's ranked shortlist, best first.
  ///
  /// Hivemind's absolute score carries a large constant offset, so the useful
  /// signal is how the alternatives compare with each other. Showing the
  /// shortlist is what makes that readable; a single number is not.
  List<BughouseInfo> get lines => ours.lines;

  /// The engine knobs, loaded from preferences and applied to the process.
  BughouseEngineSettings _engineSettings = const BughouseEngineSettings();
  BughouseEngineSettings get engineSettings => _engineSettings;

  /// Applies new engine settings and starts the search over on them.
  void setEngineSettings(BughouseEngineSettings next) {
    if (next == _engineSettings) return;
    final before = _engineSettings;
    _engineSettings = next;
    unawaited(next.save());
    if (next.reconfigures(before)) _session.markOptionsDirty();
    // Every knob here changes what the engine would answer, so what it has
    // already answered no longer describes this search.
    _clearAnalysis();
    notifyListeners();
  }

  /// How that shows up in the search: how many ranked lines each pass reports.
  int get shortlistSize => _engineSettings.lines;

  /// How long each pass thinks, doubling until it caps.
  ///
  /// Hivemind has no `go infinite` — an unbounded `go` stops after about a
  /// second — so "keeps thinking" is built from passes that each think longer
  /// than the last. Nothing carries over between them (the tree is rebuilt
  /// every time, measured), so a longer pass is the only way to a deeper
  /// answer, and the first ones are short so a number appears immediately.
  static const int _firstPassMs = 2000;
  static const int _comparePassMs = 6000;

  /// Where the doubling stops — the user's "how hard should it think".
  int get _longestPassMs => _engineSettings.thinkSeconds * 1000;

  int _passMs = _firstPassMs;

  /// Whether the time stance follows the clocks or is set by hand.
  bool deriveTimeAdvantageFromClocks = false;

  /// Extra constraint sent with each search: forbid passing on one board.
  RequireMoveOn requireMoveOn = RequireMoveOn.none;

  /// Results of the last "compare clocks" run, in the order they were run.
  List<BughouseScenarioResult> scenarios = const [];

  // ------------------------------------------------------------------- modes

  void setMode(BughouseMode mode) {
    if (_mode == mode) return;
    final left = _mode;
    _mode = mode;
    _pendingDrop = null;
    if (left == BughouseMode.tournament) {
      // A match sets `Hash` and `BatchSize` to its own snapshotted values, so
      // the pane's are no longer what the process is running with.
      _session.markOptionsDirty();
    }
    // `_wantsAnalysis` is false in every mode but `play`, so this both cuts
    // the pass in flight short and leaves the pump stopped — which is how the
    // tournament gets the process to itself.
    _clearAnalysis();
    notifyListeners();
  }

  // -------------------------------------------------------------- tournament

  BughouseTournamentController? _tournaments;

  /// Match runner to use instead of making one. Tests only — the same seam as
  /// [engineOverride], for the same reason: the real one reads and writes
  /// `Documents/`.
  @visibleForTesting
  BughouseTournamentController? tournamentsOverride;

  /// The match runner, created on first use.
  ///
  /// It borrows this controller's engine rather than starting a second
  /// Hivemind: the network is 54 MB and the search already uses every core, so
  /// two processes would halve the speed of both. Borrowing is safe because
  /// [BughouseMode.tournament] stops the analysis pump — see [setMode] — and
  /// every command through [BughouseEngine] is serialised anyway.
  BughouseTournamentController get tournaments =>
      tournamentsOverride ??
      (_tournaments ??= BughouseTournamentController(
        acquireEngine: _session.acquire,
        showLine: showLine,
        onIdle: _engineIdle,
      ));

  /// The last game of a match has landed and nothing is searching.
  ///
  /// A match is allowed to keep the process while the user is elsewhere — see
  /// [setOnScreen] — so this is where that exception is closed again: once the
  /// match is over and the pane is still off screen, the engine has nobody
  /// left to serve.
  void _engineIdle() {
    if (_onScreen || isDisposed) return;
    unawaited(_session.shutDown());
  }

  /// Puts a line on the boards — a game from a match, replayed.
  ///
  /// The cursor is left where the line left it, so a game being played shows
  /// its latest position and a finished one opens where the replay left it —
  /// at the start, ready to walk.
  void showLine(BughouseHistory line) {
    _history = line;
    _pendingDrop = null;
    hover.value = null;
    _analyses = const {};
    _error = null;
    _notice = null;
    notifyListeners();
  }

  void setTool(EditorTool tool) {
    if (tool == _tool) return;
    _tool = tool;
    notifyListeners();
  }

  void toggleFlip(BughouseBoard which) {
    _flipped[which] = !_flipped[which]!;
    notifyListeners();
  }

  // ---------------------------------------------------------------- settings

  /// Applies a change that is not part of either board's position to the whole
  /// line, so stepping backwards does not resurrect the old value.
  void _applyToLine(BughouseState Function(BughouseState) transform) {
    _history = _history.rerootWith(transform);
    _clearAnalysis();
    notifyListeners();
  }

  void setTeam(Side team) => _applyToLine(
    (s) => s.copyWith(
      team: team,
      timeStance: deriveTimeAdvantageFromClocks
          ? s.clocks.stanceFor(team)
          : s.timeStance,
    ),
  );

  void setTimeStance(BughouseTimeStance stance) {
    deriveTimeAdvantageFromClocks = false;
    _applyToLine((s) => s.copyWith(timeStance: stance));
  }

  void setRequireMoveOn(RequireMoveOn value) {
    requireMoveOn = value;
    _clearAnalysis();
    notifyListeners();
  }

  void setDeriveTimeAdvantage(bool value) {
    deriveTimeAdvantageFromClocks = value;
    if (value) {
      _applyToLine((s) => s.copyWith(timeStance: s.clocks.stanceFor(s.team)));
    } else {
      notifyListeners();
    }
  }

  void setClock(BughouseBoard board, Side side, Duration value) {
    // Re-rooting the line rebuilds every recorded position and throws the
    // analysis away, so a "change" that changes nothing must not happen.
    final clamped = value.isNegative ? Duration.zero : value;
    if (state.clocks.of(board, side) == clamped) return;
    _applyToLine((s) {
      final clocks = s.clocks.withClock(board, side, clamped);
      return s.copyWith(
        clocks: clocks,
        timeStance: deriveTimeAdvantageFromClocks
            ? clocks.stanceFor(s.team)
            : s.timeStance,
      );
    });
  }

  // ------------------------------------------------------------------- setup

  /// A press on a square with the tool in hand: the brush places its piece
  /// (pressing the piece it already holds removes it), the eraser clears the
  /// square, the pointer does nothing — it moves pieces by dragging.
  ///
  /// [erase] clears whatever is there whichever tool is selected — the same
  /// bargain every position editor makes, and the reason the eraser tool is
  /// a convenience rather than the only way out.
  void applyTool(BughouseBoard which, Square square, {bool erase = false}) {
    final Piece? piece;
    if (erase) {
      piece = null;
    } else {
      switch (_tool) {
        case PieceBrush(piece: final brush):
          final existing = state.board(which).board.pieceAt(square);
          piece = existing == brush ? null : brush;
        case EraserTool():
          piece = null;
        case PointerTool():
          return;
      }
    }
    _setPieceAt(which, square, piece);
  }

  /// The held pointer crossed onto [square]: keep painting without the
  /// toggle, so a stroke fills every square it touches.
  void paintSquare(BughouseBoard which, Square square) {
    switch (_tool) {
      case PieceBrush(:final piece):
        if (state.board(which).board.pieceAt(square) == piece) return;
        _setPieceAt(which, square, piece);
      case EraserTool():
        if (state.board(which).board.pieceAt(square) == null) return;
        _setPieceAt(which, square, null);
      case PointerTool():
        break;
    }
  }

  /// Right-click on a square: a brush swaps to the other colour, otherwise
  /// the square is cleared.
  void secondaryPress(BughouseBoard which, Square square) {
    if (_tool case PieceBrush(:final flipped)) {
      setTool(flipped);
    } else {
      applyTool(which, square, erase: true);
    }
  }

  void _setPieceAt(BughouseBoard which, Square square, Piece? piece) {
    final next = state.withPieceAt(which, square, piece);
    if (next == null) {
      _fail('That leaves an impossible position.');
      return;
    }
    _replaceCurrent(next);
  }

  void setTurn(BughouseBoard which, Side turn) =>
      _replaceCurrent(state.withTurn(which, turn));

  void setCastlingRight(
    BughouseBoard which,
    Side side,
    CastlingSide castlingSide,
    bool enabled,
  ) {
    final next = state.withCastlingRight(which, side, castlingSide, enabled);
    if (next == null) {
      _fail('There is no rook on the square that right needs.');
      return;
    }
    _replaceCurrent(next);
  }

  void editPocket(BughouseBoard which, Side side, Role role, int delta) =>
      _replaceCurrent(state.withPocket(which, side, role, delta));

  void clearBoard(BughouseBoard which) =>
      _replaceCurrent(state.clearBoard(which));

  void resetBoard(BughouseBoard which) =>
      _replaceCurrent(state.resetBoard(which));

  /// Replaces the position under the cursor and drops the rest of the line —
  /// editing a position invalidates every move that followed it.
  void _replaceCurrent(BughouseState next) {
    _history = BughouseHistory(next);
    _pendingDrop = null;
    _clearAnalysis();
    notifyListeners();
  }

  bool loadDualFen(String fen) {
    final parsed = BughouseState.tryParseDualFen(
      fen,
      team: state.team,
      timeStance: state.timeStance,
    );
    if (parsed == null) {
      _fail('That is not a valid dual FEN.');
      return false;
    }
    _replaceCurrent(parsed.copyWith(clocks: state.clocks));
    _notice = 'Position loaded.';
    notifyListeners();
    return true;
  }

  void newGame() {
    _history = BughouseHistory(
      BughouseState.initial().copyWith(
        team: state.team,
        timeStance: state.timeStance,
        clocks: state.clocks,
      ),
    );
    _pendingDrop = null;
    _clearAnalysis();
    notifyListeners();
  }

  // -------------------------------------------------------------------- play

  /// Picks a piece up out of a reserve, or puts it back down if it was already
  /// selected.
  void selectPocketPiece(BughouseBoard which, Side side, Role role) {
    if (state.board(which).pockets?.of(side, role) == 0) return;
    final pending = _pendingDrop;
    if (pending != null &&
        pending.board == which &&
        pending.side == side &&
        pending.role == role) {
      _pendingDrop = null;
    } else {
      _pendingDrop = (board: which, side: side, role: role);
    }
    notifyListeners();
  }

  /// Holds a reserve piece for the duration of a drag, so the legal squares
  /// light up while it is in the air.
  void holdPocketPiece(BughouseBoard which, Side side, Role role) {
    if (state.board(which).pockets?.of(side, role) == 0) return;
    _pendingDrop = (board: which, side: side, role: role);
    notifyListeners();
  }

  void releasePocketPiece() {
    if (_pendingDrop == null) return;
    _pendingDrop = null;
    notifyListeners();
  }

  /// Drops a held reserve piece straight onto [square] — the end of a drag,
  /// where there is no "picked up" step to undo.
  bool dropPieceOn(BughouseBoard which, Side side, Role role, Square square) {
    _pendingDrop = null;
    if (state.board(which).turn != side) {
      _fail('It is not ${side.name}\'s turn on ${which.label.toLowerCase()}.');
      return false;
    }
    if (!_play(which, DropMove(to: square, role: role))) {
      _fail('That drop is not legal.');
      return false;
    }
    notifyListeners();
    return true;
  }

  /// A click on a square while a reserve piece is held. Returns true when it
  /// consumed the click.
  bool tryDropOn(BughouseBoard which, Square square) {
    final pending = _pendingDrop;
    if (pending == null || pending.board != which) return false;
    if (state.board(which).turn != pending.side) {
      _fail(
        'It is not ${pending.side.name}\'s turn on ${which.label.toLowerCase()}.',
      );
      _pendingDrop = null;
      notifyListeners();
      return true;
    }
    final move = DropMove(to: square, role: pending.role);
    if (!_play(which, move)) {
      _fail('That drop is not legal.');
    }
    _pendingDrop = null;
    notifyListeners();
    return true;
  }

  /// Plays a board move. Illegal moves are ignored, as on any board widget.
  void playMove(BughouseBoard which, Move move) {
    if (_play(which, move)) notifyListeners();
  }

  bool _play(BughouseBoard which, Move move) {
    if (_history.play(which, move) == null) return false;
    _clearAnalysis(keepCalibration: true);
    return true;
  }

  /// Plays our team's best joint action.
  void playBestMove() => playJoint(best);

  /// Plays whichever halves of a joint move are real moves.
  ///
  /// A joint move can touch both boards at once, so this may add two plies —
  /// board A first, matching the order the engine reports them. It takes the
  /// opponents' action as readily as ours: seeing what they are about to do is
  /// half the reason to look at their search at all.
  void playJoint(BughouseJointMove? best) {
    if (best == null || best.isEmpty) return;
    if (!_playJoint(best)) _fail('The engine\'s move is not legal here.');
    notifyListeners();
  }

  /// Plays an engine line up to and including [throughPly], the way clicking
  /// a move in any engine's principal variation plays the line to there.
  ///
  /// The steps are replayed from the position on screen, not trusted: a click
  /// can land after the search that produced the line has been superseded,
  /// and a line that stops playing is left where it stopped.
  void playLine(List<BughousePvStep> steps, {required int throughPly}) {
    var played = 0;
    for (final step in steps.take(throughPly + 1)) {
      if (!_playJoint(step.action)) break;
      played++;
    }
    if (played == 0) _fail('That line no longer fits the position.');
    notifyListeners();
  }

  /// The plies of one joint action, without a notification. False when
  /// neither half is playable here.
  bool _playJoint(BughouseJointMove action) {
    // Both halves are resolved against the position the engine saw, before
    // either is applied. Resolving B after playing A would let a piece
    // captured on A pay for a drop on B in the same action — the engine never
    // chose that, because it decided both halves from one position.
    final before = state;
    final resolved = <BughouseBoard, Move>{};
    for (final which in BughouseBoard.values) {
      final half = action.half(which);
      final uci = half.uci;
      if (half.isPass || uci == null) continue;
      final position = before.board(which);
      final move = parseEngineUci(position, uci);
      if (move != null && position.isLegal(move)) resolved[which] = move;
    }
    if (resolved.isEmpty) return false;
    for (final entry in resolved.entries) {
      _play(entry.key, entry.value);
    }
    return true;
  }

  // ---------------------------------------------------------------- notation

  /// One half of a joint action as SAN on the current position — `Nxf7+`
  /// rather than `f5f7`, and `sit` for a pass. Falls back to the raw UCI when
  /// the move will not parse here, which is what a stale result looks like.
  String describeHalf(BughouseBoard which, BughouseJointMove move) =>
      _notation.describeHalf(which, move);

  /// A joint action broken into the people who make it, dropping the halves
  /// that were never a decision — see [BughouseNotation.describeSeats].
  ///
  /// [team] is the colour on board A of the team that was searched, which is
  /// what decides whether a row is you, your partner, or one of the two people
  /// playing against you.
  List<BughouseSeatMove> describeSeats(
    BughouseJointMove action, {
    required Side team,
  }) => _notation.describeSeats(action, team: team);

  /// The same thing on one line, for a shortlist row or a table cell.
  String describeJoint(BughouseJointMove action, {Side? team}) =>
      _notation.describeJoint(action, team: team ?? state.team);

  /// Just the moves, in board order — for a row that sits under one already
  /// naming the seats, where repeating the names costs a line wrap and buys
  /// nothing.
  String describeMoves(BughouseJointMove action, {Side? team}) =>
      _notation.describeMoves(action, team: team ?? state.team);

  /// The engine's whole line in SAN, ply by ply, split across the two seats
  /// that carry it — see [BughouseNotation.describePv].
  List<BughousePvStep> describePv(
    BughouseInfo info, {
    required Side team,
    int maxPlies = 6,
  }) => _notation.describePv(info, team: team, maxPlies: maxPlies);

  // -------------------------------------------------------------- navigation

  void goTo(int index) {
    _history.goTo(index);
    _pendingDrop = null;
    _clearAnalysis(keepCalibration: true);
    notifyListeners();
  }

  void back() => goTo(_history.cursor - 1);
  void forward() => goTo(_history.cursor + 1);
  void toStart() => goTo(0);
  void toEnd() => goTo(_history.length);

  void undo() {
    if (_history.undo() == null) return;
    _pendingDrop = null;
    _clearAnalysis(keepCalibration: true);
    notifyListeners();
  }

  // ---------------------------------------------------------------- analysis

  /// Whether the engine should be thinking at all right now.
  bool get _wantsAnalysis =>
      _analysisEnabled &&
      _onScreen &&
      _mode == BughouseMode.play &&
      !isDisposed;

  /// Told by the pane as it comes and goes.
  ///
  /// Leaving stops the search *and* shuts the process down: an idle Hivemind
  /// still holds its 54 MB network and spins ONNX Runtime's thread pools at
  /// about a third of a core, which is not worth keeping across a session for
  /// the second or two a relaunch costs.
  void setOnScreen(bool value) {
    if (_onScreen == value) return;
    _onScreen = value;
    if (value) {
      _passMs = _firstPassMs;
      startAnalysis();
    } else {
      // Everything on the panel described a position nobody is looking at any
      // more, and will be recomputed on the way back in.
      _generation++;
      _analyses = const {};
      scenarios = const [];
      _passMs = _firstPassMs;
      // A match outlives you looking at something else. It is not an idle
      // engine holding a network for nothing — it is work in progress, and it
      // takes minutes, so leaving the pane must not throw it away. The
      // searches keep going and the games are on the panel when you come back;
      // [_engineIdle] takes the process down once the last one lands.
      if (_tournaments?.isRunning ?? false) return notifyListeners();
      _session.stop();
      unawaited(_session.shutDown());
    }
    notifyListeners();
  }

  /// Asks for analysis to be running. Called by the pane when it appears, so
  /// that merely constructing a controller never loads a 54 MB network.
  ///
  /// Deferred by a microtask because the pane calls it from `initState`, and
  /// the pump's first act is to say it is starting the engine — a
  /// [notifyListeners] during a build.
  void startAnalysis() {
    if (!_wantsAnalysis || _pumping) return;
    unawaited(Future.microtask(_pump));
  }

  /// Pause and resume, the one engine control there is.
  void setAnalysisEnabled(bool enabled) {
    if (_analysisEnabled == enabled) return;
    _analysisEnabled = enabled;
    if (enabled) {
      // A fresh look, not a resumption of the pass that was cut off.
      _passMs = _firstPassMs;
      startAnalysis();
    } else {
      _generation++;
      _session.stop();
    }
    notifyListeners();
  }

  /// Drops what the engine said and starts it over on the position as it is
  /// now. Every edit, move and rule change goes through here.
  ///
  /// [keepCalibration] is what separates the two kinds of change. A move keeps
  /// the measured offset, because the next position is one ply away and its
  /// offset is all but the same — and that is exactly the case where the pair
  /// may be unobtainable, since a team with nothing to move gets no score at
  /// all. A change of the rules or a wholly new position does not: a different
  /// stance is a different pair of searches, and its offset is a different
  /// number.
  void _clearAnalysis({bool keepCalibration = false}) {
    _generation++;
    // Whatever was lit up described a position or a search that is gone.
    hover.value = null;
    if (!keepCalibration) _carried = null;
    _analyses = const {};
    _passMs = _firstPassMs;
    _clearError();
    _notice = null;
    scenarios = const [];
    // Cuts the pass in flight short; its result is dropped by generation.
    _session.stop();
    startAnalysis();
  }

  void _clearError() {
    _error = null;
    _errorReport = null;
    _errorLink = null;
  }

  void _fail(String message) {
    _clearError();
    _error = message;
    notifyListeners();
  }

  /// Records a failure and, when the engine attached one, the report behind it.
  void _failWith(Object e, String fallback) {
    _error = _describe(e, fallback);
    _errorReport =
        (e is BughouseEngineFailure ? e.report : null) ??
        BughouseEngineReport.unavailable(e);
    _errorLink = e is BughouseEngineFailure ? e.helpUrl : null;
  }

  /// Keeps thinking about the current position, alternating teams and giving
  /// each pass longer than the last, until something says stop.
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_wantsAnalysis) {
        final generation = _generation;
        final position = state;

        final BughouseAnalysisEngine engine;
        try {
          engine = await _session.acquire();
        } catch (e) {
          // A missing bundle or a network that will not load is permanent
          // until the user does something about it: say so once and stop,
          // rather than failing in a loop.
          _failWith(e, 'Analysis failed');
          _analysisEnabled = false;
          notifyListeners();
          return;
        }
        if (generation != _generation) continue;

        for (final team in [position.team, position.team.opposite]) {
          if (!_wantsAnalysis || generation != _generation) break;
          // A team with no move on either board has nothing to search. Asking
          // anyway burns a pass and comes back with `bestmove (none)`, which
          // is what used to be reported as the engine having no answer.
          if (!position.hasMoveFor(team)) continue;
          await _think(engine, position, team, generation);
        }
        if (generation == _generation) {
          _passMs = math.min(_passMs * 2, _longestPassMs);
        }
      }
    } finally {
      _pumping = false;
      _thinkingFor = null;
      notifyListeners();
    }
  }

  /// One pass for one team. Results from a stale generation are discarded.
  Future<void> _think(
    BughouseAnalysisEngine engine,
    BughouseState position,
    Side team,
    int generation,
  ) async {
    _thinkingFor = team;
    _thinkingGeneration = generation;
    notifyListeners();
    try {
      await _session.applyOptions(engine, _engineSettings);
      await engine.configure(
        team: team,
        hasTimeAdvantage: position.timeAdvantageFor(team),
        // The constraint is ours to obey; the opponents are not bound by it.
        requireMoveOn: team == position.team
            ? requireMoveOn
            : RequireMoveOn.none,
        multiPv: shortlistSize,
      );
      await engine.setPosition(position);
      final result = await engine.search(
        movetime: Duration(milliseconds: _passMs),
      );
      if (generation != _generation) return;
      if (_errorReport != null) _clearError();
      _analyses = {
        ..._analyses,
        team: BughouseTeamAnalysis(
          team: team,
          latest: result.principal ?? _analysisFor(team).latest,
          lines: result.lines,
          best: result.best,
        ),
      };
      // A pass that completes the pair re-measures the offset. Kept on the
      // controller so the next position — which may be one where our team has
      // nothing to move, and so can never be measured — still has one.
      final measured = BughouseCalibration.measure(
        ours.principal,
        theirs.principal,
      );
      if (measured != null) _carried = measured;
    } catch (e) {
      if (generation != _generation) return;
      _failWith(e, 'Analysis failed');
      _analysisEnabled = false;
    } finally {
      _thinkingFor = null;
      notifyListeners();
    }
  }

  /// What has to come out of a raw score before it means anything here.
  ///
  /// Measured from the two searches this pane already runs every pass, because
  /// the offset is not a constant — it is the network's estimate of what the
  /// clock advantage is worth *in this position*, which is large in the
  /// opening and small in an endgame. See [BughouseCalibration].
  ///
  /// Falls back to the last position's measurement, and then to the opening
  /// position's, so a state where one team holds both moves — the one case
  /// where a pair cannot be had at all, since the engine answers a team with
  /// nothing to move with no score whatsoever — still prints a number.
  BughouseCalibration get calibration =>
      BughouseCalibration.measure(ours.principal, theirs.principal) ??
      _carried?.asCarried ??
      BughouseCalibration.assumed(
        weMaySit: state.timeAdvantageFor(state.team),
        theyMaySit: state.timeAdvantageFor(state.team.opposite),
      );

  /// The last offset actually measured, kept across moves.
  ///
  /// Not across a change of the rules: a different stance is a different pair
  /// of searches, and its offset is a different number.
  BughouseCalibration? _carried;

  /// The position as our team reads it: one number, one percentage.
  ///
  /// Our own search answers this whenever we have one. When the whole opposing
  /// team is on move we do not — there is no move for us to search — so the
  /// opponents' number is turned around and shown instead, which is a truer
  /// answer than an empty pane.
  BughouseEval? get eval {
    final applies = calibration;
    final mine = ours.latest;
    if (mine != null) return BughouseEval.of(mine, applies);
    final other = theirs.latest;
    if (other == null) return null;
    // Their search, read from our seat. Both halves of the turn are now
    // measured against the same offset, so the headline no longer jumps by
    // the width of the clock advantage as the move passes between teams.
    return BughouseEval.of(other, applies, borrowed: true).flipped;
  }

  /// One line of either team's search, always read from our seat.
  BughouseEval evalOf(BughouseInfo info, {required Side team}) {
    final read = BughouseEval.of(info, calibration);
    return team == state.team ? read : read.flipped;
  }

  /// Folds a live `info` line into the team currently being searched, so the
  /// score moves while a pass runs instead of jumping when it ends.
  void _onInfo(BughouseInfo info) {
    // Only the top line is a running score; the lower ranks would make the
    // number jump between alternatives while the search is live. Hivemind
    // prints the ranked block once, at the end of a pass.
    if (info.multipv != 1) return;
    final team = _thinkingFor;
    if (team == null || _thinkingGeneration != _generation) return;
    final current = _analysisFor(team);
    _analyses = {..._analyses, team: current.withLatest(info)};
    notifyListeners();
  }

  /// What to put in the banner.
  ///
  /// [BughouseEngineFailure.toString] prefixes its own class name, which is
  /// meaningless to the person reading it and was the first thing on screen
  /// when the engine failed to start; the message alone is the sentence that
  /// was written to be read. The two bundle exceptions already read as plain
  /// English, so they keep their [Object.toString].
  static String _describe(Object e, String fallback) => switch (e) {
    BughouseEngineFailure() => e.message,
    BughouseBundleMissing() || BughouseBundleBroken() => e.toString(),
    _ => '$fallback: $e',
  };

  /// The rows of a scenario comparison, in the order they are run.
  ///
  /// The engine's clock model is one bit, so "equal" and "they may sit"
  /// search identically and are reported as one row. The third row forces a
  /// move, which is the case those two cannot express.
  static const List<({String label, bool advantage, RequireMoveOn require})>
  _scenarioRuns = [
    (label: 'We may sit', advantage: true, require: RequireMoveOn.none),
    (
      label: 'Equal or they may sit',
      advantage: false,
      require: RequireMoveOn.none,
    ),
    (
      label: 'Forced to move on 1',
      advantage: false,
      require: RequireMoveOn.boardA,
    ),
  ];

  /// Runs the same position under every clock scenario and tabulates them.
  ///
  /// This is the honest way to answer "what changes if I am not up on time":
  /// see [_scenarioRuns] for the three rows.
  ///
  /// Every row costs **two** searches, one per team, and that is the whole
  /// point of the table. The offset in a raw score is mostly the network
  /// reading its own `TimeAdvantage` bit, so it is a different number in the
  /// row where we may sit than in the rows where we may not — and a table that
  /// took one fixed number out of all three rows reported sitting as worth
  /// about half a pawn more than the engine actually said it was. Measuring
  /// each row's offset from its own pair is what makes the rows comparable at
  /// all, and it is why they are the same searches the pump runs rather than
  /// something cheaper.
  Future<void> compareScenarios() async {
    if (_comparing) return;
    // The pump has to let go of the engine first: one process, one search.
    final resume = _analysisEnabled;
    _analysisEnabled = false;
    _generation++;
    _session.stop();
    _comparing = true;
    _clearError();
    _notice = null;
    scenarios = const [];
    notifyListeners();

    final position = state;
    final generation = _generation;

    final collected = <BughouseScenarioResult>[];
    try {
      final engine = await _session.acquire();
      await _session.applyOptions(engine, _engineSettings);
      for (final run in _scenarioRuns) {
        // The boards stay live while this runs, so a move played mid-comparison
        // bumps the generation and cuts the search in flight short. Without
        // this check the loop kept filling in a table for a position that is
        // no longer on screen, one of whose rows was truncated.
        if (isDisposed || generation != _generation) return;
        final ours = await _scenarioSearch(
          engine,
          position,
          team: position.team,
          hasTimeAdvantage: run.advantage,
          requireMoveOn: run.require,
        );
        if (generation != _generation) return;

        // The other team under the complementary stance: if we may sit they
        // may not, and in the rows where we may not, neither may they. The
        // constraint is ours alone.
        final theirs = await _scenarioSearch(
          engine,
          position,
          team: position.team.opposite,
          hasTimeAdvantage: false,
          requireMoveOn: RequireMoveOn.none,
        );
        if (generation != _generation) return;

        final measured = BughouseCalibration.measure(
          ours.principal,
          theirs.principal,
        );
        collected.add(
          BughouseScenarioResult(
            label: run.label,
            best: ours.best,
            info: ours.principal,
            calibration:
                measured ??
                BughouseCalibration.assumed(
                  weMaySit: run.advantage,
                  theyMaySit: false,
                ),
          ),
        );
        scenarios = List.unmodifiable(collected);
        notifyListeners();
      }
    } catch (e) {
      // A search that was cut short because the user moved on is not a
      // failure to report — the generation says which it was.
      if (generation == _generation) {
        _failWith(e, 'Comparison failed');
      }
    } finally {
      _comparing = false;
      _analysisEnabled = resume;
      _passMs = _firstPassMs;
      startAnalysis();
      notifyListeners();
    }
  }

  /// One configured search for the scenario table.
  Future<BughouseSearchResult> _scenarioSearch(
    BughouseAnalysisEngine engine,
    BughouseState position, {
    required Side team,
    required bool hasTimeAdvantage,
    required RequireMoveOn requireMoveOn,
  }) async {
    await engine.configure(
      team: team,
      hasTimeAdvantage: hasTimeAdvantage,
      requireMoveOn: requireMoveOn,
    );
    await engine.setPosition(position);
    return engine.search(
      movetime: const Duration(milliseconds: _comparePassMs),
    );
  }

  @override
  void dispose() {
    // Only a process this controller launched is ours to stop — see
    // [BughouseEngineSession.dispose].
    _session.dispose();
    // Only one this controller made: an injected runner outlives the pane,
    // exactly as an injected engine does.
    _tournaments?.dispose();
    _tournaments = null;
    _book?.close();
    _book = null;
    hover.dispose();
    super.dispose();
  }
}
