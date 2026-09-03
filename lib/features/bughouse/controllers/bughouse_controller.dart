import 'dart:async';
import 'dart:math' as math;

import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';

import '../../../utils/safe_change_notifier.dart';
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
  }

  /// Injected engine, for tests and for pointing at a local engine build.
  final BughouseEngine? engineOverride;

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
  void hoverAction(BughouseJointMove? action) {
    if (identical(_hovered, action)) return;
    _hovered = action;
    notifyListeners();
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

  /// A pocket piece the user picked up, awaiting a destination square.
  ({BughouseBoard board, Side side, Role role})? _pendingDrop;
  ({BughouseBoard board, Side side, Role role})? get pendingDrop =>
      _pendingDrop;

  BughouseEngine? _engine;
  BughouseEngine? get engine => _engine;

  bool _starting = false;
  bool get isStarting => _starting;

  /// Whether the pump is allowed to run. Toggled by the pause button, and by
  /// leaving the play pane; it is not "is a search running right now".
  bool _analysisEnabled = true;
  bool get analysisEnabled => _analysisEnabled;

  /// Which team the engine is thinking about this instant, null between
  /// passes. Both teams are searched in turn, so this is what the spinner
  /// should follow rather than a single "is searching" flag.
  Side? _thinkingFor;
  Side? get thinkingFor => _thinkingFor;
  bool get isThinking => _thinkingFor != null;

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

  /// How many ranked lines to ask for. Not a user knob: three is what fits
  /// beside the boards, and more lines cost the same search nothing.
  static const int shortlistSize = 3;

  /// How long each pass thinks, doubling until it caps.
  ///
  /// Hivemind has no `go infinite` — an unbounded `go` stops after about a
  /// second — so "keeps thinking" is built from passes that each think longer
  /// than the last. Nothing carries over between them (the tree is rebuilt
  /// every time, measured), so a longer pass is the only way to a deeper
  /// answer, and the first ones are short so a number appears immediately.
  static const int _firstPassMs = 2000;
  static const int _longestPassMs = 30000;
  static const int _comparePassMs = 6000;

  int _passMs = _firstPassMs;

  /// Whether the time stance follows the clocks or is set by hand.
  bool deriveTimeAdvantageFromClocks = false;

  /// Extra constraint sent with each search: forbid passing on one board.
  RequireMoveOn requireMoveOn = RequireMoveOn.none;

  /// Results of the last "compare clocks" run, in the order they were run.
  List<BughouseScenarioResult> scenarios = const [];

  StreamSubscription<BughouseInfo>? _infoSub;

  String get backendLabel => _engine?.backend ?? '';
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
    _applyToLine((s) {
      final clocks = s.clocks.withClock(board, side, value);
      return s.copyWith(
        clocks: clocks,
        timeStance: deriveTimeAdvantageFromClocks
            ? clocks.stanceFor(s.team)
            : s.timeStance,
      );
    });
  }

  // ------------------------------------------------------------------- setup

  void applyTool(BughouseBoard which, Square square) {
    final piece = switch (_tool) {
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
    var played = false;
    for (final which in BughouseBoard.values) {
      final half = best.half(which);
      if (half.isPass || half.uci == null) continue;
      final move = _parseUci(state.board(which), half.uci!);
      if (move != null && _play(which, move)) played = true;
    }
    if (!played) _fail('The engine\'s move is not legal here.');
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

  /// Parses the engine's UCI, including `P@e5` drops.
  static Move? _parseUci(Crazyhouse position, String uci) {
    final move = Move.parse(uci);
    if (move == null) return null;
    if (move is NormalMove && move.promotion == null) {
      // A pawn reaching the last rank without an explicit promotion is a queen
      // by convention.
      final piece = position.board.pieceAt(move.from);
      final lastRank = position.turn == Side.white ? 7 : 0;
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
      _analysisEnabled && _mode == BughouseMode.play && !isDisposed;

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

        final BughouseEngine engine;
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
    BughouseEngine engine,
    BughouseState position,
    Side team,
    int generation,
  ) async {
    _thinkingFor = team;
    notifyListeners();
    try {
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
  ({String label, double fraction, bool borrowed})? get eval {
    final mine = ours.latest;
    if (mine != null) {
      return (
        label: mine.evalLabel,
        fraction: mine.barFraction,
        borrowed: false,
      );
    }
    final other = theirs.latest;
    if (other == null) return null;
    return (
      label: flipEval(other.evalLabel),
      fraction: 1 - other.barFraction,
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
    if (team == null) return;
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
      for (final run in runs) {
        if (isDisposed) return;
        await engine.configure(
          team: position.team,
          hasTimeAdvantage: run.advantage,
          requireMoveOn: run.require,
        );
        await engine.setPosition(position);
        final result = await engine.search(
          movetime: const Duration(milliseconds: _comparePassMs),
        );
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
      _error = _describe(e, 'Comparison failed');
    } finally {
      _comparing = false;
      _analysisEnabled = resume;
      _passMs = _firstPassMs;
      startAnalysis();
      notifyListeners();
    }
  }

  Future<BughouseEngine> _ensureEngine() async {
    final existing = _engine ?? engineOverride;
    if (existing != null) {
      _engine = existing;
      return existing;
    }
    _starting = true;
    notifyListeners();
    try {
      final executable = await BughouseBundle.ensureInstalled();
      final engine = await BughouseEngine.launch(
        executablePath: executable,
        modelPath: BughouseBundle.modelPath!,
        libraryPath: BughouseBundle.libraryPath,
      );
      _infoSub = engine.infoStream.listen(_onInfo);
      _engine = engine;
      return engine;
    } finally {
      _starting = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    unawaited(_infoSub?.cancel() ?? Future.value());
    unawaited(_engine?.dispose() ?? Future.value());
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
