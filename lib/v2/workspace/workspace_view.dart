import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/theme.dart';
import 'board_view.dart';
import 'chapter_header.dart';
import 'comment_panel.dart';
import 'document_saver.dart';
import 'document_session.dart';
import 'engine_analysis.dart';
import 'engine_pane.dart';
import 'eval_bar.dart';
import 'move_tree_view.dart';

/// The board with its evaluation bar on the left; the chapter, the engine,
/// the moves and their comment on the right; arrow keys to walk the line and
/// Ctrl+Z to take the last edit back.
class WorkspaceView extends StatelessWidget {
  const WorkspaceView({
    super.key,
    required this.session,
    required this.saver,
    required this.analysis,
    this.moveMenu,
  });

  final DocumentSession session;
  final DocumentSaver saver;
  final EngineAnalysis analysis;

  /// What a right-click on a move offers, which is the mode's business: a
  /// study marks where a quiz starts, and nothing else offers anything yet.
  final MoveMenu? moveMenu;

  void _undo() => unawaited(session.undo());

  Map<ShortcutActivator, VoidCallback> get _bindings => {
    const SingleActivator(LogicalKeyboardKey.arrowLeft): session.back,
    const SingleActivator(LogicalKeyboardKey.arrowRight): session.forward,
    const SingleActivator(LogicalKeyboardKey.arrowUp): session.toStart,
    const SingleActivator(LogicalKeyboardKey.arrowDown): session.toEnd,
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true): _undo,
    const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _undo,
  };

  /// A key the workspace answers to, unless the user is typing: in a text
  /// field the arrows move the caret and Ctrl+Z takes back a word, and those
  /// keys are the field's. Ignoring the event leaves it to the field, which
  /// is why this is not [CallbackShortcuts]: that reports every bound key as
  /// handled and the field would never see it.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_typing) return KeyEventResult.ignored;
    for (final MapEntry(key: activator, value: run) in _bindings.entries) {
      if (activator.accepts(event, HardwareKeyboard.instance)) {
        run();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  bool get _typing {
    final focused = FocusManager.instance.primaryFocus?.context;
    return focused != null &&
        focused.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(Space.l),
              child: _BoardWithBar(session: session, analysis: analysis),
            ),
          ),
          const VerticalDivider(width: 1),
          SizedBox(
            width: 360,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ChapterHeader(session: session, saver: saver),
                const Divider(height: 1),
                EnginePane(analysis: analysis),
                const Divider(height: 1),
                Expanded(
                  child: MoveTreeView(session: session, moveMenu: moveMenu),
                ),
                const Divider(height: 1),
                CommentPanel(session: session),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The largest square board that fits beside the bar, at the top.
class _BoardWithBar extends StatelessWidget {
  const _BoardWithBar({required this.session, required this.analysis});

  final DocumentSession session;
  final EngineAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = min(
          constraints.maxWidth - evalBarWidth - Space.s,
          constraints.maxHeight,
        );
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: side,
            child: ListenableBuilder(
              listenable: Listenable.merge([session, analysis]),
              builder: (context, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  EvalBar(
                    score: analysis.snapshot?.best?.score,
                    orientation: session.orientation,
                  ),
                  const SizedBox(width: Space.s),
                  SizedBox(
                    width: side,
                    child: BoardView(
                      fen: session.fen,
                      orientation: session.orientation,
                      lastMove: session.currentMove?.uci,
                      onMove: session.playMove,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
