import 'dart:async';

import 'package:flutter/material.dart';

import '../chess/pgn/analysis_board.dart' show analysisBoard;
import '../features/library/library.dart';
import '../storage/chapter_files.dart';
import '../ui/app_action.dart';
import '../ui/app_keys.dart';
import '../ui/choice_dialog.dart';
import '../ui/name_dialog.dart';
import '../workspace/board_editor.dart';
import '../workspace/study_drafts.dart';
import '../workspace/workspace.dart';
import 'mode.dart';
import 'workspace_requests.dart';

/// The ways a position comes onto an analysis board from outside a file:
/// the clipboard and the board editor. While the Analysis tab is up they
/// fill that tab's scratch game and leave the file beside it alone;
/// otherwise each is a new analysis board ([WorkspaceRequests.paste]).
final class BoardDoors {
  BoardDoors({
    required this.requests,
    required this.workspace,
    required this.inspecting,
  });

  final WorkspaceRequests requests;
  final Workspace workspace;

  /// Whether the Analysis tab is the board on screen.
  final bool Function() inspecting;

  /// Ctrl+V, or Ctrl+Shift+V for [positionOnly].
  Future<void> paste({bool positionOnly = false}) async {
    final inspection = workspace.inspection;
    if (inspection == null || !inspecting()) {
      await (positionOnly ? requests.pasteFen() : requests.paste());
      return;
    }
    final source = workspace.session.source;
    final game = workspace.session.game;
    final text = await requests.input.clipboard() ?? '';
    if (!inspecting() ||
        source != workspace.session.source ||
        game != workspace.session.game) {
      return;
    }
    requests.say(await inspection.paste(text, positionOnly: positionOnly));
  }

  /// [screen], a mode's own, with Ctrl+V and Ctrl+Shift+V answered there
  /// too — they say why such a mode cannot take what the clipboard holds,
  /// or take it to the builder — unless a text field has the caret, whose
  /// paste they are then.
  Widget? onScreen(Widget? screen) => screen == null
      ? null
      : Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (_, event) {
            final positionOnly = AppKey.pastePosition.accepts(event);
            if (_typing || !(positionOnly || AppKey.paste.accepts(event))) {
              return KeyEventResult.ignored;
            }
            unawaited(paste(positionOnly: positionOnly));
            return KeyEventResult.handled;
          },
          child: screen,
        );

  static bool get _typing =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>() !=
      null;

  /// The board editor on the position on the board, seen as it is seen;
  /// the position set up comes back as an analysis board, the same way up.
  Future<void> setUp(BuildContext context) async {
    final inspection = workspace.inspection;
    final inspected = inspection != null && inspecting();
    final session = inspected ? inspection.session : workspace.session;
    final side = session.orientation;
    final fen = await showBoardEditor(
      context,
      initial: session.boardFen,
      orientation: side,
    );
    if (fen == null) return;
    if (inspected && inspecting()) {
      return inspection.put(analysisBoard(side: side, root: fen));
    }
    await requests.openPosition(fen, side: side);
  }

  /// Paste and Set up, for the Actions menu. [paste] is false where Ctrl+V
  /// makes a repertoire of a PGN: the entry is then the FEN-only paste.
  List<AppAction> entries(BuildContext context, {bool paste = true}) => [
    paste
        ? AppAction(
            AppKey.paste.action,
            () => unawaited(this.paste()),
            shortcut: AppKey.paste.label,
            group: 'Board',
          )
        : AppAction(
            AppKey.pastePosition.action,
            () => unawaited(this.paste(positionOnly: true)),
            shortcut: AppKey.pastePosition.label,
            group: 'Board',
          ),
    AppAction(
      'Set up position…',
      () => unawaited(setUp(context)),
      shortcut: AppKey.setUpPosition.label,
      group: 'Board',
    ),
  ];
}

/// The analysis board's doors in the Actions menu: back to it, a new one
/// from the position on the board, the clipboard and the board editor, and
/// — while it is up — the two ways to keep it. Each way to keep it asks two
/// questions, one dialog each: where, then what to call it.
List<AppAction> boardActions(
  BuildContext context, {
  required BoardDoors doors,
  required Library library,
  required VoidCallback? onAnalyze,
}) {
  final requests = doors.requests;
  final session = doors.workspace.session;
  final scratch = session.isScratch;
  final inLibrary =
      requests.mode == Mode.repertoires || requests.mode == Mode.trainer;
  return [
    if (onAnalyze != null)
      AppAction(
        'Open Analysis tab',
        onAnalyze,
        shortcut: AppKey.analysisBoard.label,
        group: 'Board',
      ),
    // In the builder and the trainer Ctrl+V makes a repertoire of a PGN,
    // which the file entry offers; the board takes a FEN.
    ...doors.entries(context, paste: scratch || !inLibrary),
    if (scratch && requests.mode == Mode.repertoires)
      AppAction(
        'Save to repertoire…',
        () => unawaited(_toRepertoire(context, requests, library)),
        group: 'Document',
      ),
    if (scratch && requests.mode == Mode.study)
      AppAction(
        'Save to study…',
        () => unawaited(requests.addToStudy([?gameDraft(session)])),
        group: 'Document',
      ),
  ];
}

Future<void> _toRepertoire(
  BuildContext context,
  WorkspaceRequests requests,
  Library library,
) async {
  final into = await showChoiceDialog<RepertoireFolder>(
    context,
    title: 'Save to repertoire',
    options: library.repertoires,
    label: (folder) => folder.name,
    hint: 'Type a repertoire',
    empty: 'No repertoires yet',
  );
  if (into == null || !context.mounted) return;
  final name = await _chapterName(context, into.name);
  if (name == null) return;
  await requests.saveBoardToRepertoire(into, name);
}

Future<String?> _chapterName(BuildContext context, String into) async {
  if (!context.mounted) return null;
  return showNameDialog(
    context,
    title: 'New chapter in $into',
    label: 'Chapter name',
    confirm: 'Save',
  );
}
