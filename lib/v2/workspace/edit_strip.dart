import 'package:flutter/material.dart';

import '../chess/pgn/comment_edits.dart' show isGlyph;
import '../chess/pgn/comment_text.dart';
import '../chess/pgn/game_tree.dart';
import '../ui/app_action.dart';
import '../ui/listening_state.dart';
import '../ui/theme.dart';
import 'comment_field.dart';
import 'copy_name_dialog.dart';
import 'document_saver.dart';
import 'document_session.dart';
import 'session_results.dart';

/// Everything about changing the document, under the moves: Done, Undo, the
/// save state, the six glyphs and the note on the move the board is on.
///
/// It exists while [editing] is on and the whole game is on view, while
/// the file has edits that are not saved (the PGN Viewer's), and otherwise
/// only when there is trouble to report — a save that failed, a
/// file that changed on disk, a file this app may not write, an edit that
/// was refused — because reading a file is not editing it and needs none of
/// this on screen. Trouble shows the state line, the ways out and the
/// reason; the glyphs and the field wait for editing.
class EditStrip extends StatefulWidget {
  const EditStrip({
    super.key,
    required this.session,
    required this.saver,
    required this.editing,
  });

  final DocumentSession session;
  final DocumentSaver saver;
  final ValueNotifier<bool> editing;

  @override
  State<EditStrip> createState() => _EditStripState();
}

class _EditStripState extends State<EditStrip> with ListeningState<EditStrip> {
  /// The answer to the last thing the user asked for here, until the
  /// document changes under it.
  String? _notice;
  Object? _about;

  @override
  Listenable listenableOf(EditStrip widget) => widget.session;

  @override
  void initState() {
    super.initState();
    _about = widget.session.source;
  }

  /// Another document drops the answer about the last one.
  @override
  void changed() {
    if (widget.session.source == _about) return;
    setState(() {
      _about = widget.session.source;
      _notice = null;
    });
  }

  Future<void> _undo() async {
    final result = await widget.session.undo();
    if (!mounted) return;
    setState(
      () => _notice = switch (result) {
        Restored() => null,
        UndoRefused(:final reason) => reason ?? 'Nothing to undo right now',
      },
    );
  }

  Future<void> _reload() async {
    final result = await widget.session.reloadFromDisk();
    if (!mounted) return;
    setState(
      () => _notice = switch (result) {
        DocumentOpened() || OpenOvertaken() => null,
        OpenFailed(:final reason) => reason,
      },
    );
  }

  Future<void> _saveCopy() async {
    final name = await showCopyNameDialog(
      context,
      widget.session.chapter?.name ?? 'Chapter',
    );
    if (name == null || !mounted) return;
    final result = await widget.session.saveCopy(name);
    if (!mounted) return;
    setState(() => _notice = copySaid(result));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.session,
        widget.saver,
        widget.editing,
      ]),
      builder: (context, _) {
        // While part of the game is hidden — a puzzle's answer — the note
        // on the start and the moves' glyphs would give it away.
        final editing =
            widget.editing.value &&
            widget.session.chapter != null &&
            widget.session.shownTo == null;
        final state = widget.saver.state;
        final refusal = widget.session.refusedEdit;
        final trouble = _trouble(state) || refusal != null || _notice != null;
        final held = widget.session.hasHeldEdits;
        if (!editing && !trouble && !held) return const SizedBox.shrink();
        return Container(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(
            Space.m,
            Space.s,
            Space.m,
            Space.s,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _stateRow(editing, state),
              if (_waysOut(state) case final reload?)
                _WaysOut(
                  reload: reload,
                  onReload: _reload,
                  onSaveCopy: _saveCopy,
                ),
              if (refusal != null) _Notice(_refusalNotice(refusal)),
              if (_notice case final notice?) _Notice(notice),
              if (editing) ...[
                const SizedBox(height: Space.s),
                _Glyphs(session: widget.session),
                const SizedBox(height: Space.s),
                CommentField(session: widget.session),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _stateRow(bool editing, SaveState state) => Row(
    children: [
      if (editing) ...[
        Tooltip(
          message: withKey('Done editing', 'Ctrl+E'),
          child: FilledButton(
            onPressed: () => widget.editing.value = false,
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('Done'),
          ),
        ),
        const SizedBox(width: Space.s),
        IconButton(
          onPressed: widget.session.canUndo ? _undo : null,
          icon: const Icon(Icons.undo, size: IconSize.action),
          tooltip: withKey('Undo', 'Ctrl+Z'),
          visualDensity: VisualDensity.compact,
        ),
        const SizedBox(width: Space.s),
      ],
      Expanded(
        child: switch (widget.session) {
          DocumentSession(isScratch: true) => const _Notice('Not saved'),
          DocumentSession(hasHeldEdits: true) => const _Notice(
            'Unsaved changes',
          ),
          // The viewer keeps edits off the file, so there is nothing for
          // the save line to report until one is made.
          DocumentSession(holdsEdits: true) => const _Notice(
            'Edits stay unsaved until you save them',
          ),
          _ => _SaveLine(state: state),
        },
      ),
      if (widget.session.hasHeldEdits) ...[
        TextButton(
          onPressed: widget.session.discardHeld,
          child: const Text('Discard'),
        ),
        const SizedBox(width: Space.s),
        Tooltip(
          message: withKey('Save to the file', 'Ctrl+S'),
          child: FilledButton(
            onPressed: widget.session.keepHeld,
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('Save'),
          ),
        ),
      ],
    ],
  );
}

bool _trouble(SaveState state) =>
    state is SaveFailed ||
    state is SaveConflict ||
    state is SaveStopped ||
    state is DocumentReadOnly;

/// What the screen tells the user about an edit that did not happen.
String _refusalNotice(EditRefused refusal) => switch (refusal) {
  NotEditable(:final detail) =>
    'This file opened to read: $detail. Save a copy to edit it here.',
  LineNotWhole() =>
    'That line could not be read in full, so it is left as it is. Edit it '
        'in the old app.',
  WordsRefused(:final reason) =>
    'The note was not saved: $reason. Take it out and try again.',
  EditNotWritten(:final reason) =>
    'That change was not made: $reason. The chapter is as it was.',
  MoveLost() => 'That move could not be written, so nothing was saved.',
};

/// The save state in words. Only a failure and a conflict take a colour:
/// everything else is ordinary and reads as ordinary.
class _SaveLine extends StatelessWidget {
  const _SaveLine({required this.state});

  final SaveState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      switch (state) {
        Saved() => 'Saved',
        Saving() => 'Saving…',
        Unsaved() => 'Unsaved',
        SaveFailed(:final detail) => 'Could not save: $detail',
        SaveConflict() => 'The file changed on disk',
        SaveStopped() =>
          'The app tried to change a line you did not edit, so the save was '
              'stopped. Nothing was written and nothing more will be: your '
              'words are still on screen.',
        // The sentence is on the notice below, where the store's own reason
        // for it can be. Saying it twice reads as two problems.
        DocumentReadOnly() => 'Read only',
      },
      style: theme.textTheme.bodySmall?.copyWith(
        color: _trouble(state) ? theme.colorScheme.error : null,
      ),
    );
  }
}

/// What the Reload button says in [state], or null when the document is not
/// one the user has to choose about.
///
/// A stopped save says what reloading costs, because the words on screen are
/// in no file and nothing is going to write them: taking what is on disk
/// throws them away. A file that opened to read has nothing to lose, so its
/// only real way out is a copy.
String? _waysOut(SaveState state) => switch (state) {
  SaveConflict() || SaveStopped() => 'Reload and lose the words on screen',
  DocumentReadOnly() => 'Reload',
  _ => null,
};

class _WaysOut extends StatelessWidget {
  const _WaysOut({
    required this.reload,
    required this.onReload,
    required this.onSaveCopy,
  });

  final String reload;
  final VoidCallback onReload;
  final VoidCallback onSaveCopy;

  @override
  Widget build(BuildContext context) {
    // Wrapped rather than a row: one of these labels says what reloading
    // costs, which is longer than a narrow panel has room for.
    return Wrap(
      spacing: Space.s,
      children: [
        TextButton(onPressed: onReload, child: Text(reload)),
        TextButton(onPressed: onSaveCopy, child: const Text('Save a copy…')),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: Theme.of(context).textTheme.bodySmall);
}

/// The six marks a reader prints after a move, one at a time: pressing the
/// one the move has takes it off. Off at the start position, which is not a
/// move. It follows the cursor itself; the strip around it does not.
class _Glyphs extends StatelessWidget {
  const _Glyphs({required this.session});

  final DocumentSession session;

  static const _nags = [3, 1, 5, 6, 2, 4];

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: session.cursorListenable,
    builder: (context, at, _) => _buttons(at),
  );

  Widget _buttons(NodePath at) {
    final move = session.currentMove;
    final current = move?.nags.where(isGlyph).firstOrNull;
    return ToggleButtons(
      isSelected: [for (final nag in _nags) nag == current],
      onPressed: move == null
          ? null
          : (index) {
              final nag = _nags[index];
              session.setGlyph(at, nag == current ? null : nag);
            },
      constraints: const BoxConstraints(
        minWidth: glyphButtonWidth,
        minHeight: glyphButtonHeight,
      ),
      children: [
        for (final nag in _nags) Text(nagGlyph(nag)!, style: monoText),
      ],
    );
  }
}
