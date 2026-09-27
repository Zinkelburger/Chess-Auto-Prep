import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../chess/pgn/chapter.dart';
import '../ui/app_action.dart';
import 'document_session.dart';
import 'engine_analysis.dart';

/// What can be done to the document on the board, whatever mode opened it:
/// the Actions menu's second half. Each entry is off when there is nothing
/// open, rather than missing, so the menu keeps its shape.
List<AppAction> documentActions({
  required DocumentSession session,
  required EngineAnalysis analysis,
  required ValueNotifier<bool> editing,
  required VoidCallback onSaveCopy,
}) {
  final open = session.chapter != null;
  VoidCallback? when(bool on, VoidCallback run) => on ? run : null;
  return [
    AppAction(
      editing.value ? 'Done editing' : 'Edit',
      when(open, () => editing.value = !editing.value),
      shortcut: 'Ctrl+E',
      group: 'Document',
    ),
    AppAction(
      'Undo',
      when(session.canUndo, () => unawaited(session.undo())),
      shortcut: 'Ctrl+Z',
      group: 'Document',
    ),
    if (session.hasHeldEdits) ...[
      AppAction(
        'Save changes',
        session.keepHeld,
        shortcut: 'Ctrl+S',
        group: 'Document',
      ),
      AppAction('Discard changes', session.discardHeld, group: 'Document'),
    ],
    AppAction(
      'Save a copy…',
      when(session.source != null, onSaveCopy),
      group: 'Document',
    ),
    AppAction(
      'Flip board',
      when(open, session.flip),
      shortcut: 'F',
      group: 'Board',
    ),
    // Off at any time, on only while the whole game is on view, as E is:
    // the engine would read a hidden puzzle answer out.
    AppAction(
      analysis.enabled ? 'Engine off' : 'Engine on',
      when(
        analysis.enabled || session.shownTo == null,
        () => unawaited(
          analysis.enabled ? analysis.disable() : analysis.enable(),
        ),
      ),
      shortcut: 'E',
      group: 'Board',
    ),
    AppAction(
      'Copy game PGN',
      when(open, () => _copy(gameText(session))),
      group: 'Copy',
    ),
    AppAction(
      'Copy FEN',
      when(open, () => _copy(session.fen.value)),
      group: 'Copy',
    ),
  ];
}

/// The text of the game on the board: the one game of a viewed file, or
/// the whole file when a chapter's games are merged.
String gameText(DocumentSession session) {
  final chapter = session.chapter;
  if (chapter == null) return '';
  final index = chapter.game;
  if (index != null && index < chapter.lines.length) {
    return chapter.lines[index].text;
  }
  return writeChapter(chapter);
}

void _copy(String text) =>
    unawaited(Clipboard.setData(ClipboardData(text: text)));
