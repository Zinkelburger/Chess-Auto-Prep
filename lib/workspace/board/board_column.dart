import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../chess/fen.dart';
import '../../storage/settings_store.dart';
import '../../ui/listening_state.dart';
import '../../ui/theme.dart';
import 'board_claim.dart';
import 'board_view.dart';
import '../document/document_session.dart';
import '../analysis/engine_analysis.dart';
import '../analysis/engine_pane.dart';
import 'game_counter.dart';
import '../document/game_ordering.dart';
import 'move_field.dart';
import '../reading/move_note.dart';
import 'move_shapes.dart';

/// The largest square board that fits above the engine's lines and the
/// row with the move field and the counter, at the top, and the move's note
/// in what they leave below, when that is enough to read a few lines in.
class BoardAndCounter extends StatefulWidget {
  const BoardAndCounter({
    super.key,
    required this.session,
    required this.settings,
    required this.onMove,
    required this.counter,
    this.ordering,
    required this.moves,
    required this.engine,
    required this.analysis,
    this.noteEditable = false,
    this.editing,
    this.quiet = false,
    this.engineInBoard = true,
  });

  final DocumentSession session;
  final SettingsStore settings;
  final EngineAnalysis analysis;
  final bool noteEditable;
  final ValueNotifier<bool>? editing;

  /// Whether the engine's row, the move field and an empty note stay away
  /// until they are used ([WorkspaceHooks.quietBoard]).
  final bool quiet;

  /// Training provides the shared engine in its Analysis tool pane.
  final bool engineInBoard;

  /// Where a move made on the board or typed into the field goes.
  final ValueChanged<String> onMove;

  /// Whether the game counter sits under the board.
  final bool counter;
  final GameOrdering? ordering;
  final MoveEntry moves;

  /// The engine's lines, under the counter, or its settings while the
  /// notifier it is given says so.
  final Widget Function(ValueNotifier<bool> settingsOpen) engine;

  @override
  State<BoardAndCounter> createState() => _BoardAndCounterState();
}

class _BoardAndCounterState extends State<BoardAndCounter>
    with ListeningState<BoardAndCounter> {
  double _engineRoom = 0;

  /// Whether the engine shows its settings in place of its lines, kept for
  /// as long as the board is.
  final _engineSettings = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _engineRoom = _room();
  }

  @override
  void dispose() {
    stopListening();
    _engineSettings.dispose();
    super.dispose();
  }

  /// The engine's room, the same whether it is on, off, paused, showing
  /// its settings or kept out of a hidden answer, so none of those changes
  /// the board's size. Only the number of lines asked for changes it.
  double _room() =>
      widget.engineInBoard ? enginePaneHeight(widget.analysis) : 0;

  @override
  void didUpdateWidget(BoardAndCounter oldWidget) {
    super.didUpdateWidget(oldWidget);
    _engineRoom = _room();
  }

  @override
  Listenable listenableOf(BoardAndCounter widget) => widget.analysis;

  @override
  void changed() {
    final room = _room();
    if (!mounted || room == _engineRoom) return;
    setState(() => _engineRoom = room);
  }

  /// The engine in its room; on a quiet board the room stays blank until
  /// the engine is on.
  Widget _engine() => ListenableBuilder(
    listenable: widget.analysis,
    builder: (context, _) => widget.quiet && !widget.analysis.enabled
        ? const SizedBox.shrink()
        : SingleChildScrollView(child: widget.engine(_engineSettings)),
  );

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final settings = widget.settings;
    final onMove = widget.onMove;
    return LayoutBuilder(
      builder: (context, constraints) {
        final room = navRowHeight + moveFeedbackHeight + Space.s + _engineRoom;
        final noteRoom = widget.editing != null || widget.noteEditable
            ? moveNoteMinHeight + Space.s
            : 0.0;
        final side = min(
          constraints.maxWidth,
          max(0.0, constraints.maxHeight - room - noteRoom),
        );
        final below = constraints.maxHeight - side - room - Space.s;
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: side,
            child: Column(
              children: [
                ListenableBuilder(
                  listenable: Listenable.merge([
                    session.anyChange,
                    settings,
                    widget.analysis.threat,
                    ?widget.editing,
                  ]),
                  // A comment's line on the board is read, not played on.
                  builder: (context, _) {
                    final keeps = drawsIntoComment(
                      session,
                      editing: widget.editing?.value ?? false,
                    );
                    return BoardView(
                      fen: session.cursor.boardFen,
                      orientation: session.orientation,
                      lastMove: session.cursor.boardLastMove,
                      onMove: onMove,
                      movable: session.cursor.commentLine.value == null,
                      coordinates: settings.value.boardCoordinates,
                      shapes: shapesOnBoard(session),
                      threat: threatOnBoard(
                        session,
                        widget.analysis.threat.value,
                      ),
                      onDraw: keeps
                          ? (shape) => drawIntoComment(session, shape)
                          : null,
                      onClear: keeps ? () => clearCommentShapes(session) : null,
                    );
                  },
                ),
                const SizedBox(height: Space.s),
                SizedBox(height: _engineRoom, child: _engine()),
                _navigation(),
                MoveFeedback(entry: widget.moves),
                if (below >= moveNoteMinHeight) _note(side, below),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The move's note in the room left under the row, [side] wide.
  Widget _note(double side, double below) => Padding(
    padding: const EdgeInsets.only(top: Space.s),
    child: SizedBox(
      width: side,
      height: below,
      child: MoveNote(
        session: widget.session,
        editable: widget.noteEditable,
        editing: widget.editing,
        quiet: widget.quiet,
      ),
    ),
  );

  Widget _navigation() => SizedBox(
    height: navRowHeight,
    child: Row(
      children: [
        ListenableBuilder(
          listenable: widget.session.anyChange,
          builder: (context, _) => _Typed(
            moves: widget.moves,
            fen: widget.session.cursor.boardFen,
            onMove: widget.session.cursor.commentLine.value == null
                ? widget.onMove
                : null,
            whenUsed: widget.quiet,
          ),
        ),
        Expanded(
          child: widget.counter
              ? GameCounter(session: widget.session, ordering: widget.ordering)
              : const SizedBox.shrink(),
        ),
      ],
    ),
  );
}

/// The board while another owner holds it: its position and the move
/// field alone. No engine space is reserved while a lesson owns the board.
class ClaimedBoard extends StatelessWidget {
  const ClaimedBoard({
    super.key,
    required this.claim,
    required this.settings,
    required this.moves,
  });

  final BoardClaim claim;
  final SettingsStore settings;
  final MoveEntry moves;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const room = navRowHeight + moveFeedbackHeight + Space.s;
        final side = min(constraints.maxWidth, constraints.maxHeight - room);
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: side,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListenableBuilder(
                  listenable: settings,
                  builder: (context, _) => BoardView(
                    fen: claim.fen,
                    orientation: claim.orientation,
                    lastMove: claim.lastMove,
                    onMove: claim.onMove ?? _still,
                    movable: claim.onMove != null,
                    coordinates: settings.value.boardCoordinates,
                  ),
                ),
                const SizedBox(height: Space.s),
                SizedBox(
                  height: navRowHeight,
                  child: _Typed(
                    moves: moves,
                    fen: claim.fen,
                    onMove: claim.onMove,
                  ),
                ),
                MoveFeedback(entry: moves),
              ],
            ),
          ),
        );
      },
    );
  }

  static void _still(String uci) {}
}

/// The move field at its width, in the row under the board.
class _Typed extends StatelessWidget {
  const _Typed({
    required this.moves,
    required this.fen,
    required this.onMove,
    this.whenUsed = false,
  });

  final MoveEntry moves;
  final Fen fen;
  final ValueChanged<String>? onMove;

  /// Whether the field is seen only while it has the keys or words in it.
  final bool whenUsed;

  @override
  Widget build(BuildContext context) {
    final field = SizedBox(
      width: moveFieldWidth,
      child: Center(
        child: MoveField(entry: moves, fen: fen, onMove: onMove),
      ),
    );
    return whenUsed ? _WhenUsed(moves: moves, child: field) : field;
  }
}

/// The move field seen only while it has the keys or words in it. It keeps
/// its place and stays in the tree either way, so `/` finds it and nothing
/// beside it moves when it comes.
class _WhenUsed extends StatefulWidget {
  const _WhenUsed({required this.moves, required this.child});

  final MoveEntry moves;
  final Widget child;

  @override
  State<_WhenUsed> createState() => _WhenUsedState();
}

class _WhenUsedState extends State<_WhenUsed> with ListeningState<_WhenUsed> {
  bool _used = false;

  @override
  void initState() {
    super.initState();
    _used = _usedNow;
  }

  bool get _usedNow =>
      widget.moves.focus.hasFocus || widget.moves.words.text.isNotEmpty;

  @override
  Listenable listenableOf(_WhenUsed widget) =>
      Listenable.merge([widget.moves.focus, widget.moves.words]);

  @override
  void dispose() {
    stopListening();
    super.dispose();
  }

  /// The field under this clears its own words while it is being built, on
  /// a new position; that is heard here, above it, so the change is shown
  /// once the frame is done.
  @override
  void changed() {
    if (!mounted || _usedNow == _used) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => changed());
      return;
    }
    setState(() => _used = _usedNow);
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: !_used,
    child: Opacity(opacity: _used ? 1 : 0, child: widget.child),
  );
}
