import 'dart:async';

import 'package:flutter/material.dart';

import '../chess/pgn/analysis_board.dart' show analysisBoard;
import '../chess/pgn/tree_edit.dart' show pathOfSans;
import '../features/library/library.dart';
import '../storage/chapter_files.dart';
import '../storage/finds_store.dart';
import '../ui/app_action.dart';
import '../ui/app_keys.dart';
import '../ui/choice_dialog.dart';
import '../ui/name_dialog.dart';
import '../workspace/board/board_editor.dart';
import '../workspace/document/study_drafts.dart';
import '../workspace/workspace.dart';
import 'mode.dart';
import 'workspace_requests.dart';

/// The ways a position comes onto an analysis board from outside a file:
/// the clipboard and the board editor. While the Analysis tab is up they
/// fill that tab's scratch game and leave the file beside it alone;
/// otherwise each is a new analysis board ([WorkspaceRequests.paste]). A
/// find from the Positions comes the same way, unless the open chapter
/// already plays its line ([openFind]).
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

  /// Ctrl+V, or Actions ▸ Paste FEN for [positionOnly].
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

  /// [screen], a mode's own, with Ctrl+V answered there too — it says why
  /// such a mode cannot take what the clipboard holds, or takes it to the
  /// builder — unless a text field has the caret, whose paste it is then.
  Widget? onScreen(Widget? screen) => screen == null
      ? null
      : Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (_, event) {
            if (_typing || !AppKey.paste.accepts(event)) {
              return KeyEventResult.ignored;
            }
            unawaited(paste());
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
      initial: session.cursor.boardFen,
      orientation: side,
    );
    if (fen == null) return;
    if (inspected && inspecting()) {
      return inspection.put(analysisBoard(side: side, root: fen));
    }
    await requests.openPosition(fen, side: side);
  }

  /// A find's position in the open chapter when the chapter plays its line
  /// that far, else its line on an analysis board at its position.
  void openFind(KeptFind kept) {
    workspace.finds.select(kept.id);
    final session = workspace.session;
    final tree = session.tree;
    if (!inspecting() &&
        session.source != null &&
        tree != null &&
        tree.rootFen.position == kept.rootFen.position) {
      final path = pathOfSans(
        tree,
        kept.find.sans.take(kept.find.ply).toList(),
      );
      if (path != null) {
        session.cursor.goTo(path);
        return;
      }
    }
    unawaited(
      requests.openLine(
        root: kept.rootFen,
        sans: kept.find.sans,
        ply: kept.find.ply,
        side: kept.side,
      ),
    );
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
            'Paste FEN',
            () => unawaited(this.paste(positionOnly: true)),
            group: 'Board',
          ),
    AppAction(
      'Edit position…',
      () => unawaited(setUp(context)),
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
        AppKey.analysisBoard.action,
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
        'Add game to study…',
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
  final into = await showChoiceDialog<_SaveInto>(
    context,
    title: 'Save to repertoire',
    // A new repertoire first: the one choice there always is.
    options: [
      const _NewRepertoire(),
      for (final folder in library.repertoires) _Existing(folder),
    ],
    label: (target) => switch (target) {
      _NewRepertoire() => 'New repertoire…',
      _Existing(:final folder) => folder.name,
    },
    hint: 'Type a repertoire',
    empty: 'No repertoire by that name',
  );
  if (into == null || !context.mounted) return;
  switch (into) {
    case _NewRepertoire():
      final name = await showNameDialog(
        context,
        title: 'Create repertoire',
        label: 'Repertoire name',
        confirm: 'Create',
      );
      if (name == null) return;
      await requests.saveBoardAsRepertoire(name);
    case _Existing(:final folder):
      final name = await _chapterName(context, folder.name);
      if (name == null) return;
      await requests.saveBoardToRepertoire(folder, name);
  }
}

/// Where the analysis board is saved: a repertoire there is, or a new one.
sealed class _SaveInto {
  const _SaveInto();
}

final class _NewRepertoire extends _SaveInto {
  const _NewRepertoire();
}

final class _Existing extends _SaveInto {
  const _Existing(this.folder);

  final RepertoireFolder folder;
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
