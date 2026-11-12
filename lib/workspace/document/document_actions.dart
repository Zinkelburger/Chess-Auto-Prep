import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chess/pgn/chapter.dart';
import '../../ui/app_action.dart';
import '../../ui/app_icons.dart';
import '../../ui/app_keys.dart';
import '../analysis/engine_analysis.dart';
import 'document_session.dart';

/// What can be done to the document on the board, whatever mode opened it:
/// the Actions menu's second half. Each entry is off when there is nothing
/// open, rather than missing, so the menu keeps its shape.
List<AppAction> documentActions({
  required DocumentSession session,
  required EngineAnalysis analysis,
  required ValueNotifier<bool> editing,
  required VoidCallback onSaveCopy,
  VoidCallback? onSaveHeld,
}) {
  final open = session.chapter != null;
  VoidCallback? when(bool on, VoidCallback run) => on ? run : null;
  return [
    AppAction(
      editing.value ? 'Done editing' : 'Edit',
      when(open, () => editing.value = !editing.value),
      icon: editing.value ? AppIcons.done : AppIcons.edit,
      group: 'Document',
    ),
    if (!session.holdsEdits || session.canUndo || editing.value)
      AppAction(
        'Undo',
        when(session.canUndo, () => unawaited(session.undo())),
        shortcut: AppKey.undo.label,
        group: 'Document',
        icon: AppIcons.undo,
      ),
    if (session.hasHeldEdits) ...[
      AppAction(
        AppKey.save.action,
        onSaveHeld ?? session.keepHeld,
        shortcut: AppKey.save.label,
        group: 'Document',
        icon: AppIcons.save,
      ),
      AppAction('Discard changes', session.discardHeld, group: 'Document'),
    ],
    AppAction(
      'Save a copy…',
      when(session.source != null, onSaveCopy),
      group: 'Document',
      icon: AppIcons.saveCopy,
    ),
    AppAction(
      'Flip board',
      when(open, session.flip),
      shortcut: AppKey.flip.label,
      group: 'Board',
    ),
    // Off at any time, on only while the whole game is on view: the engine
    // would read a hidden puzzle answer out.
    AppAction(
      analysis.enabled ? 'Engine off' : 'Engine on',
      when(
        analysis.enabled || session.shownTo == null,
        () => unawaited(analysis.turn(!analysis.enabled)),
      ),
      group: 'Board',
    ),
    AppAction(
      'Copy game PGN',
      when(open, () => _copy(gameText(session))),
      group: 'Copy',
      icon: AppIcons.copy,
    ),
    AppAction(
      'Copy FEN',
      when(open, () => _copy(session.cursor.fen.value)),
      group: 'Copy',
      icon: AppIcons.copy,
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
