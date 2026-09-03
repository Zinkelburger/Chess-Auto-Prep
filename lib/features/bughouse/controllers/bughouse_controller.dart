import 'dart:async';
import 'dart:math' as math;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../../../models/board_annotation.dart';
import '../../../utils/chess_utils.dart' show roleChar;
import '../../../utils/safe_change_notifier.dart';
import '../models/bughouse_engine_settings.dart';
import '../models/bughouse_history.dart';
import '../models/bughouse_state.dart';
import '../services/bughouse_bundle.dart';
import '../services/bughouse_engine.dart';

/// Setting a position up versus playing a line through.
enum BughouseMode { play, setup }

/// What a click on a board does while in setup mode.
sealed class SetupTool {
  const SetupTool();
}

/// Place this piece.
class PlaceTool extends SetupTool {
  const PlaceTool(this.piece);
  final Piece piece;
}

/// Clear the clicked square.
class EraseTool extends SetupTool {
  const EraseTool();
}

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
  BughouseController({this.engineOverride}) {
    _history = BughouseHistory(BughouseState.initial());
    unawaited(_loadEngineSettings());
  }

  Future<void> _loadEngineSettings() async {
    final loaded = await BughouseEngineSettings.load();
    if (isDisposed || loaded == _engineSettings) return;
    _engineSettings = loaded;
    // The process, if one is already up, is running on the defaults.
    _optionsDirty = true;
    notifyListeners();
  }

  /// Injected engine, for tests and for pointing at a local engine build.
  ///
  /// Typed as the interface rather than the process client, so a test can hand
  /// in a scripted fake — the pump, the generation invalidation and the
  /// scenario comparison are the parts most worth covering and were previously
  /// unreachable without launching a real 54 MB engine.
  final BughouseAnalysisEngine? engineOverride;

  late BughouseHistory _history;
  BughouseHistory get history => _history;

  BughouseState get state => _history.current;

  BughouseMode _mode = BughouseMode.play;
  BughouseMode get mode => _mode;

  SetupTool _tool = const PlaceTool(Piece(color: Side.white, role: Role.pawn));
  SetupTool get tool => _tool;

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

  /// The joint action the pointer is over in the panel, lit up on the boards.
  BughouseJointMove? _hovered;

  /// Called by a line in the panel as the pointer enters and leaves it.
  ///
  /// [silently] is for teardown: a row unmounted while the pointer is over it
  /// clears the highlight from `State.dispose`, which runs inside
  /// `finalizeTree` where the tree is locked — notifying there threw
  /// "markNeedsBuild() called when widget tree was locked" on every click of a
  /// line, the panel's headline interaction. Nothing needs repainting in that
  /// case anyway: the rows are on their way out.
  void hoverAction(BughouseJointMove? action, {bool silently = false}) {
    if (identical(_hovered, action)) return;
    _hovered = action;
    if (!silently) notifyListeners();
  }

  /// Drops the highlight only if [action] is the one currently lit.
  ///
  /// A row unmounting must not clear a highlight another row has just taken,
  /// which a bare `hoverAction(null)` did whenever the block rebuilt under the
  /// pointer.
  void clearHoverIfOwned(BughouseJointMove action, {bool silently = false}) {
    if (!identical(_hovered, action)) return;
    hoverAction(null, silently: silently);
  }

  /// The squares [which] should light up because a line is being hovered.
  ///
  /// A joint action moves on two boards at once, so hovering one row lights
  /// both — which is the whole reason to do it rather than print more text.
  Set<String> hoveredSquares(BughouseBoard which) {
    final action = _hovered;
    if (action == null) return const {};
    final half = action.half(which);
    final uci = half.uci;
    if (half.isPass || uci == null) return const {};
    final move = _parseUci(state.board(which), uci);
    return switch (move) {
      NormalMove(:final from, :final to) => {from.name, to.name},
      DropMove(:final to) => {to.name},
      _ => const {},
    };
  }

  /// Arrows and drop markers for [which] — the engine's answer, drawn on the
  /// board instead of only spelled out beside it.
  ///
  /// Reading a joint action off a text row is the hard part of bughouse
  /// notation: two boards move at once, and half the moves are drops with no
  /// origin square to trace. So the shortlist row under the pointer wins the
  /// boards outright (blue, both halves), and with nothing hovered the boards
  /// carry the two standing answers — what our team should play (green) and
  /// what the other team is about to (red), which is the pair a player checks
  /// against each other.
  List<BoardAnnotation> annotationsFor(BughouseBoard which) {
    if (_mode != BughouseMode.play) return const [];
    final hovered = _hovered;
    if (hovered != null) {
      return _annotate(which, hovered, AnnotationBrush.blue);
    }
    return [
      ..._annotate(which, ours.best, AnnotationBrush.green),
      ..._annotate(which, theirs.best, AnnotationBrush.red),
    ];
  }

  /// One half of a joint action as board shapes: an arrow for a move, and for
  /// a drop a ring on the landing square badged with the piece, because a drop
  /// comes from a reserve and so has nowhere to draw an arrow from.
  List<BoardAnnotation> _annotate(
    BughouseBoard which,
    BughouseJointMove? action,
    AnnotationBrush brush,
  ) {
    if (action == null) return const [];
    final half = action.half(which);
    final uci = half.uci;
    if (half.isPass || uci == null) return const [];
    final position = state.board(which);
    final move = _parseUci(position, uci);
    if (move == null || !position.isLegal(move)) return const [];
    return switch (move) {
      NormalMove(:final from, :final to) => [
        BoardAnnotation(orig: from.name, dest: to.name, brush: brush),
      ],
      DropMove(:final to, :final role) => [
        BoardAnnotation(
          orig: to.name,
          brush: brush,
          label: roleChar(role).toUpperCase(),
        ),
      ],
    };
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

  BughouseAnalysisEngine? _engine;
  BughouseAnalysisEngine? get engine => _engine;

  /// The launch in flight, if any. Two callers asking for the engine at once
  /// (the pump plus a "compare clocks" press during the first network load)
  /// used to start two processes, leak the first `infoStream` subscription and
  /// orphan whichever process lost the assignment.
  Future<BughouseAnalysisEngine>? _launching;

  bool _starting = false;
  bool get isStarting => _starting;

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

  /// Whether the live process still has to be told about [_engineSettings].
  ///
  /// Applied on the engine's own command queue immediately before a search
  /// rather than the moment the user turns a dial: a `setoption` sent while a
  /// pass is in flight would sit behind it anyway, and doing it here means a
  /// freshly launched process — which is back at the engine's defaults — is
  /// configured by exactly the same path.
  bool _optionsDirty = true;

  /// Applies new engine settings and starts the search over on them.
  void setEngineSettings(BughouseEngineSettings next) {
    if (next == _engineSettings) return;
    final before = _engineSettings;
    _engineSettings = next;
    unawaited(next.save());
    if (next.reconfigures(before)) _optionsDirty = true;
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

  StreamSubscription<BughouseInfo>? _infoSub;

  String get backendLabel => _engine?.backend ?? '';

  /// What the running engine reported about workers, threads and batch — the
  /// honest answer to "how many cores is it using", since Hivemind fixes its
  /// worker count and has no `Threads` option to offer.
  String get backendDetail => _engine?.backendDetail ?? '';
  bool get isReady => _engine != null;

  // ------------------------------------------------------------------- modes

  void setMode(BughouseMode mode) {
    if (_mode == mode) return;
    _mode = mode;
    _pendingDrop = null;
    _clearAnalysis();
    notifyListeners();
  }

  void setTool(SetupTool tool) {
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

  void setTeam(Side team) => _applyToLine((s) => s.copyWith(team: team));

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

  /// Places or clears a square in the editor.
  ///
  /// [erase] is the right-click path, which clears whatever is there whichever
  /// tool is selected — the same bargain every position editor makes, and the
  /// reason the eraser tool is a convenience rather than the only way out.
  void applyTool(BughouseBoard which, Square square, {bool erase = false}) {
    final piece = erase
        ? null
        : switch (_tool) {
            PlaceTool(:final piece) => piece,
            EraseTool() => null,
          };
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
    final before = state;
    final position = before.board(which);
    if (!position.isLegal(move)) return false;

    final san = position.makeSan(move).$2;
    final after = before.playMove(which, move);
    if (after == null) return false;

    _history.push(
      BughousePly(
        board: which,
        move: move,
        san: san,
        before: before,
        after: after,
      ),
    );
    _clearAnalysis();
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
    // Both halves are resolved against the position the engine saw, before
    // either is applied. Resolving B after playing A would let a piece
    // captured on A pay for a drop on B in the same action — the engine never
    // chose that, because it decided both halves from one position.
    final before = state;
    final resolved = <BughouseBoard, Move>{};
    for (final which in BughouseBoard.values) {
      final half = best.half(which);
      final uci = half.uci;
      if (half.isPass || uci == null) continue;
      final position = before.board(which);
      final move = _parseUci(position, uci);
      if (move != null && position.isLegal(move)) resolved[which] = move;
    }
    if (resolved.isEmpty) {
      _fail('The engine\'s move is not legal here.');
      notifyListeners();
      return;
    }
    for (final entry in resolved.entries) {
      _play(entry.key, entry.value);
    }
    notifyListeners();
  }

  /// One half of a joint action as SAN on the current position — `Nxf7+`
  /// rather than `f5f7`, and `sit` for a pass. Falls back to the raw UCI when
  /// the move will not parse here, which is what a stale result looks like.
  String describeHalf(BughouseBoard which, BughouseJointMove move) {
    final half = move.half(which);
    final uci = half.uci;
    if (half.isPass || uci == null) return 'sit';
    final position = state.board(which);
    final parsed = _parseUci(position, uci);
    if (parsed == null || !position.isLegal(parsed)) return uci;
    return position.makeSan(parsed).$2;
  }

  /// A joint action broken into the people who make it, dropping the halves
  /// that were never a decision.
  ///
  /// A joint action always carries two halves, so the board where the searched
  /// team is not on move comes back as a pass every single time. Printing that
  /// as `B sit` says the team chose to wait when it simply had nothing to move
  /// there, so that half is left out. A pass on a board the team *is* on move
  /// on is a real decision and still reads `sit`.
  ///
  /// [team] is the colour on board A of the team that was searched, which is
  /// what decides whether a row is you, your partner, or one of the two people
  /// playing against you.
  List<({String who, String hint, String move, BughouseBoard board})>
  describeSeats(BughouseJointMove action, {required Side team}) {
    final rows =
        <({String who, String hint, String move, BughouseBoard board})>[];
    for (final which in BughouseBoard.values) {
      final mover = which == BughouseBoard.a ? team : team.opposite;
      final half = action.half(which);
      final passing = half.isPass || half.uci == null;
      if (passing && state.board(which).turn != mover) continue;
      rows.add((
        who: state.seatLetter(which, mover),
        hint: state.seatDescription(which, mover),
        move: describeHalf(which, action),
        board: which,
      ));
    }
    return rows;
  }

  /// The same thing on one line, for a shortlist row or a table cell.
  String describeJoint(BughouseJointMove action, {Side? team}) {
    final rows = describeSeats(action, team: team ?? state.team);
    return rows.isEmpty
        ? '—'
        : rows.map((r) => '${r.who} ${r.move}').join('   ·   ');
  }

  /// Just the moves, in board order — for a row that sits under one already
  /// naming the seats, where repeating the names costs a line wrap and buys
  /// nothing.
  String describeMoves(BughouseJointMove action, {Side? team}) {
    final rows = describeSeats(action, team: team ?? state.team);
    return rows.isEmpty ? '—' : rows.map((r) => r.move).join('  ·  ');
  }

  /// The engine's whole line in SAN, ply by ply, split across the two seats
  /// that carry it.
  ///
  /// The engine speaks board-prefixed UCI and its `pv` is a list of *joint*
  /// actions, so printed raw it reads `(g1f3,pass) (b8c6,e2e4)` — which is not
  /// a line anyone can follow. Replaying it gives SAN, and splitting each ply
  /// by board gives the two columns the panel lays it out in: our seats are A
  /// on board 1 and C on board 2, theirs B and D.
  ///
  /// Both halves of a ply are resolved against the position *before* either is
  /// applied, matching [playJoint] — the engine decided them together, so a
  /// piece captured on one board must not pay for a drop on the other in the
  /// same ply. Replay stops at the first half that will not play, which is
  /// what a line from a superseded position looks like.
  ///
  /// Which team acts is read off the position for each ply rather than fixed
  /// to [team], because a variation alternates: the searched team moves, then
  /// the other two answer. That is what decides whether a `pass` in a ply is a
  /// deliberate sit or simply the half of a joint action nobody owned, and it
  /// is why each step carries the seats that played it.
  List<BughousePvStep> describePv(
    BughouseInfo info, {
    required Side team,
    int maxPlies = 6,
  }) {
    var position = state;
    final steps = <BughousePvStep>[];
    for (final action in info.pv) {
      if (steps.length >= maxPlies) break;

      // A real half is played by whoever is on turn on that board, and that
      // names the team for the whole ply — the two halves of a joint action
      // always belong to the same team.
      Side? acting;
      for (final which in BughouseBoard.values) {
        final half = action.half(which);
        if (half.isPass || half.uci == null) continue;
        final turn = position.board(which).turn;
        acting = which == BughouseBoard.a ? turn : turn.opposite;
        break;
      }
      // An all-pass ply names no team, so it stays with whoever moved last —
      // or, at the head of the line, with the team that was searched.
      acting ??= steps.isEmpty ? team : steps.last.team;

      final sans = <BughouseBoard, String>{};
      var next = position;
      var stalled = false;
      for (final which in BughouseBoard.values) {
        final mover = which == BughouseBoard.a ? acting : acting.opposite;
        final half = action.half(which);
        final uci = half.uci;
        if (half.isPass || uci == null) {
          // Sitting is only a decision on a board the team is actually on move
          // on; elsewhere the pass is just the shape of a joint action.
          if (position.board(which).turn == mover) sans[which] = 'sit';
          continue;
        }
        final board = position.board(which);
        final move = _parseUci(board, uci);
        if (move == null || !board.isLegal(move)) {
          stalled = true;
          break;
        }
        sans[which] = board.makeSan(move).$2;
        final played = next.playMove(which, move);
        if (played == null) {
          stalled = true;
          break;
        }
        next = played;
      }
      if (stalled || sans.isEmpty) break;
      steps.add(
        BughousePvStep(
          team: acting,
          seats: state.teamLetters(acting),
          onA: sans[BughouseBoard.a],
          onB: sans[BughouseBoard.b],
        ),
      );
      position = next;
    }
    return steps;
  }

  /// Parses the engine's UCI, including `P@e5` drops.
  static Move? _parseUci(Crazyhouse position, String uci) {
    final move = Move.parse(uci);
    if (move == null) return null;
    if (move is NormalMove && move.promotion == null) {
      // Belt and braces: Hivemind spells its promotions out (`b7a8q`), so this
      // has never fired against the real engine — but a bare `e7e8` is legal
      // UCI elsewhere, and a queen is the convention.
      final piece = position.board.pieceAt(move.from);
      final lastRank = piece?.color == Side.white ? 7 : 0;
      if (piece?.role == Role.pawn && move.to.rank == lastRank) {
        return NormalMove(from: move.from, to: move.to, promotion: Role.queen);
      }
    }
    return move;
  }

  // -------------------------------------------------------------- navigation

  void goTo(int index) {
    _history.goTo(index);
    _pendingDrop = null;
    _clearAnalysis();
    notifyListeners();
  }

  void back() => goTo(_history.cursor - 1);
  void forward() => goTo(_history.cursor + 1);
  void toStart() => goTo(0);
  void toEnd() => goTo(_history.length);

  void undo() {
    if (_history.undo() == null) return;
    _pendingDrop = null;
    _clearAnalysis();
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
      _engine?.stop();
      unawaited(_shutDownEngine());
    }
    notifyListeners();
  }

  /// Lets go of the engine, and stops the process unless it is one a caller
  /// handed us — an injected engine outlives the pane by definition.
  Future<void> _shutDownEngine() async {
    final engine = _engine;
    if (engine == null) return;
    _release();
    if (identical(engine, engineOverride)) return;
    await engine.dispose();
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
      _engine?.stop();
    }
    notifyListeners();
  }

  /// Drops what the engine said and starts it over on the position as it is
  /// now. Every edit, move and rule change goes through here.
  void _clearAnalysis() {
    _generation++;
    _analyses = const {};
    _passMs = _firstPassMs;
    _error = null;
    _notice = null;
    scenarios = const [];
    // Cuts the pass in flight short; its result is dropped by generation.
    _engine?.stop();
    startAnalysis();
  }

  void _fail(String message) {
    _error = message;
    notifyListeners();
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
          engine = await _ensureEngine();
        } catch (e) {
          // A missing bundle or a network that will not load is permanent
          // until the user does something about it: say so once and stop,
          // rather than failing in a loop.
          _error = _describe(e, 'Analysis failed');
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
      await _applyEngineOptions(engine);
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
      _analyses = {
        ..._analyses,
        team: BughouseTeamAnalysis(
          team: team,
          latest: result.principal ?? _analysisFor(team).latest,
          lines: result.lines,
          best: result.best,
        ),
      };
    } catch (e) {
      if (generation != _generation) return;
      _error = _describe(e, 'Analysis failed');
      _analysisEnabled = false;
    } finally {
      _thinkingFor = null;
      notifyListeners();
    }
  }

  /// The position as our team reads it: one number, one bar fraction.
  ///
  /// Our own search answers this whenever we have one. When the whole opposing
  /// team is on move we do not — there is no move for us to search — so the
  /// opponents' number is turned around and shown instead, which is a truer
  /// answer than an empty pane.
  ({String label, double winPercent, bool borrowed})? get eval {
    final mine = ours.latest;
    if (mine != null) {
      return (
        label: mine.evalLabel,
        winPercent: mine.winPercent,
        borrowed: false,
      );
    }
    final other = theirs.latest;
    if (other == null) return null;
    return (
      label: flipEval(other.evalLabel),
      // Their expected score is ours subtracted from the whole, for the same
      // reason the label is flipped: the panel only ever answers for us.
      winPercent: 100 - other.winPercent,
      borrowed: true,
    );
  }

  /// The same evaluation seen from the other side of the table, so that every
  /// number on the panel answers "how does this leave *our* team" — including
  /// the ones that came out of the opponents' search.
  static String flipEval(String label) {
    if (label.startsWith('#-')) return '#${label.substring(2)}';
    if (label.startsWith('#')) return '#-${label.substring(1)}';
    if (label.startsWith('+')) return '-${label.substring(1)}';
    if (label.startsWith('-')) return '+${label.substring(1)}';
    return label;
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

  static String _describe(Object e, String fallback) =>
      e is BughouseEngineFailure || e is BughouseBundleMissing
      ? e.toString()
      : '$fallback: $e';

  /// Runs the same position under every clock scenario and tabulates them.
  ///
  /// This is the honest way to answer "what changes if I am not up on time":
  /// the engine's clock model is one bit, so "level" and "behind" search
  /// identically and are reported as one row. The third row forces a move,
  /// which is the case those two cannot express.
  Future<void> compareScenarios() async {
    if (_comparing) return;
    // The pump has to let go of the engine first: one process, one search.
    final resume = _analysisEnabled;
    _analysisEnabled = false;
    _generation++;
    _engine?.stop();
    _comparing = true;
    _error = null;
    _notice = null;
    scenarios = const [];
    notifyListeners();

    final position = state;
    final generation = _generation;
    final runs = <({String label, bool advantage, RequireMoveOn require})>[
      (label: 'Ahead (may sit)', advantage: true, require: RequireMoveOn.none),
      (label: 'Level or behind', advantage: false, require: RequireMoveOn.none),
      (
        label: 'Forced to move on 1',
        advantage: false,
        require: RequireMoveOn.boardA,
      ),
    ];

    final collected = <BughouseScenarioResult>[];
    try {
      final engine = await _ensureEngine();
      await _applyEngineOptions(engine);
      for (final run in runs) {
        // The boards stay live while this runs, so a move played mid-comparison
        // bumps the generation and cuts the search in flight short. Without
        // this check the loop kept filling in a table for a position that is
        // no longer on screen, one of whose rows was truncated.
        if (isDisposed || generation != _generation) return;
        await engine.configure(
          team: position.team,
          hasTimeAdvantage: run.advantage,
          requireMoveOn: run.require,
        );
        await engine.setPosition(position);
        final result = await engine.search(
          movetime: const Duration(milliseconds: _comparePassMs),
        );
        if (generation != _generation) return;
        collected.add(
          BughouseScenarioResult(
            label: run.label,
            best: result.best,
            info: result.lastInfo,
          ),
        );
        scenarios = List.unmodifiable(collected);
        notifyListeners();
      }
    } catch (e) {
      // A search that was cut short because the user moved on is not a
      // failure to report — the generation says which it was.
      if (generation == _generation) {
        _error = _describe(e, 'Comparison failed');
      }
    } finally {
      _comparing = false;
      _analysisEnabled = resume;
      _passMs = _firstPassMs;
      startAnalysis();
      notifyListeners();
    }
  }

  /// Pushes [_engineSettings] into the process, once per change.
  ///
  /// `Hash` and `BatchSize` are the two that reconfigure the engine itself;
  /// `MultiPV` rides along on every [BughouseAnalysisEngine.configure] and the
  /// think time never leaves this class.
  Future<void> _applyEngineOptions(BughouseAnalysisEngine engine) async {
    if (!_optionsDirty) return;
    // Cleared first: a failure must not retry on every pass forever, and the
    // error is surfaced by the caller either way.
    _optionsDirty = false;
    await engine.setOption('Hash', _engineSettings.hashMb);
    await engine.setOption('BatchSize', _engineSettings.batchSize);
  }

  Future<BughouseAnalysisEngine> _ensureEngine() {
    final existing = _engine ?? engineOverride;
    // A process that has exited is not an engine. Without this the controller
    // kept handing back a corpse and every pass waited out its full timeout.
    if (existing != null && existing.isAlive) {
      if (!identical(_engine, existing)) _adopt(existing);
      return Future.value(existing);
    }
    if (existing != null && !existing.isAlive) {
      _release();
    }
    return _launching ??= _launch();
  }

  Future<BughouseAnalysisEngine> _launch() async {
    _starting = true;
    notifyListeners();
    try {
      final executable = await BughouseBundle.ensureInstalled();
      final engine = await BughouseEngine.launch(
        executablePath: executable,
        modelPath: BughouseBundle.modelPath!,
        libraryPath: BughouseBundle.libraryPath,
      );
      _adopt(engine);
      return engine;
    } finally {
      _launching = null;
      _starting = false;
      notifyListeners();
    }
  }

  /// Takes ownership of [engine] and starts folding its `info` lines in.
  void _adopt(BughouseAnalysisEngine engine) {
    unawaited(_infoSub?.cancel() ?? Future.value());
    _infoSub = engine.infoStream.listen(_onInfo);
    _engine = engine;
    // A process we have not configured yet is on the engine's own defaults.
    _optionsDirty = true;
  }

  /// Lets go of a dead engine so the next request starts a fresh one.
  void _release() {
    unawaited(_infoSub?.cancel() ?? Future.value());
    _infoSub = null;
    _engine = null;
  }

  @override
  void dispose() {
    unawaited(_infoSub?.cancel() ?? Future.value());
    unawaited(_engine?.dispose() ?? Future.value());
    _engine = null;
    super.dispose();
  }
}

/// What one team currently thinks about the position.
///
/// Two of these are kept at all times, because a bughouse position has no
/// single side to move: each board has its own turn, so at any moment one team
/// may hold both moves, or one each, and the team you are on may hold neither.
/// Searching only our own team is what used to leave the pane saying the
/// engine "returned no move" in exactly the positions where the interesting
/// answer was what the opponents were about to do.
class BughouseTeamAnalysis {
  const BughouseTeamAnalysis({
    required this.team,
    this.latest,
    this.lines = const [],
    this.best,
  });

  /// The colour this team plays on board A.
  final Side team;

  /// The newest top line, updated while a pass runs.
  final BughouseInfo? latest;

  /// The ranked shortlist from the last finished pass. Hivemind prints its
  /// MultiPV block once, at the end, so this lags [latest] by one pass.
  final List<BughouseInfo> lines;

  /// The joint action the last finished pass settled on.
  final BughouseJointMove? best;

  bool get isEmpty => latest == null && best == null && lines.isEmpty;

  BughouseTeamAnalysis withLatest(BughouseInfo info) =>
      BughouseTeamAnalysis(team: team, latest: info, lines: lines, best: best);
}

/// One ply of a principal variation, as the two seats that play it.
///
/// A bughouse ply is a decision about two boards at once, so it has two cells,
/// not one move. Either may be absent: a seat that is not on move has nothing
/// to decide there, which is a blank rather than a `sit`.
class BughousePvStep {
  const BughousePvStep({
    required this.team,
    required this.seats,
    required this.onA,
    required this.onB,
  });

  /// The team that plays this ply — it alternates down the variation.
  final Side team;

  /// That team's two seats, `A + C` or `B + D`, so a continuation row says
  /// whose move it is without the reader counting plies.
  final String seats;

  /// SAN for the seat on board 1 — `Nf3`, `P@e5`, or `sit` for a deliberate
  /// pass. Null when that seat had no move to make.
  final String? onA;

  /// The same for board 2.
  final String? onB;

  String? on(BughouseBoard which) => which == BughouseBoard.a ? onA : onB;
}

/// One row of a scenario comparison.
class BughouseScenarioResult {
  const BughouseScenarioResult({
    required this.label,
    required this.best,
    required this.info,
  });

  final String label;
  final BughouseJointMove? best;
  final BughouseInfo? info;
}
