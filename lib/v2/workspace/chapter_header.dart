import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../chess/pgn/chapter.dart';
import '../chess/pgn/game_summary.dart';
import '../storage/chapter_files.dart';
import '../ui/theme.dart';
import 'document_saver.dart';
import 'edit_refused.dart';
import 'save_state.dart';
import 'document_session.dart';
import 'session_results.dart';
import 'chapter_commands.dart';

/// What is open and whether it is on disk: the chapter's name and side, then
/// one line of save state. A file someone else changed offers the two ways
/// out of that — take theirs, or put yours somewhere else — and keeping the
/// draft is simply not choosing either.
class ChapterHeader extends StatefulWidget {
  const ChapterHeader({super.key, required this.session, required this.saver});

  final DocumentSession session;
  final DocumentSaver saver;

  @override
  State<ChapterHeader> createState() => _ChapterHeaderState();
}

class _ChapterHeaderState extends State<ChapterHeader> {
  /// The answer to the last thing the user asked for here.
  String? _notice;

  /// The chapter the notice is about; another one makes it somebody else's
  /// news and it goes.
  ChapterRef? _about;

  @override
  void initState() {
    super.initState();
    _about = widget.session.source;
    widget.session.addListener(_onChapter);
  }

  @override
  void dispose() {
    widget.session.removeListener(_onChapter);
    super.dispose();
  }

  void _onChapter() {
    if (!mounted || widget.session.source == _about) return;
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
    setState(
      () => _notice = switch (result) {
        CopySaved(name: final name, nowEditing: true) =>
          'Saved a copy as $name. Now editing the copy.',
        CopySaved(:final name) => 'Saved a copy as $name',
        CopyNameTaken() => 'That name is taken. Nothing was replaced.',
        CopyFailed(:final detail) => 'Could not save a copy: $detail',
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.session, widget.saver]),
      builder: (context, _) {
        final chapter = widget.session.chapter;
        if (chapter == null) {
          return Padding(
            padding: const EdgeInsets.all(Space.m),
            child: Text('Open a chapter', style: text.bodySmall),
          );
        }
        return Padding(
          padding: const EdgeInsets.all(Space.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(chapter.name, style: text.titleMedium),
              const SizedBox(height: Space.xs),
              _SideAndLines(
                chapter: chapter,
                onSide: (side) => setSide(widget.session, side),
              ),
              const SizedBox(height: Space.xs),
              Row(
                children: [
                  Expanded(child: _SaveLine(state: widget.saver.state)),
                  _UndoButton(onPressed: widget.saver.canUndo ? _undo : null),
                ],
              ),
              if (_waysOut(widget.saver.state) case final reload?)
                _WaysOut(
                  reload: reload,
                  onReload: _reload,
                  onSaveCopy: _saveCopy,
                ),
              if (widget.session.refusedEdit case final refusal?)
                _Notice(_refusalNotice(refusal)),
              if (_notice case final notice?) _Notice(notice),
            ],
          ),
        );
      },
    );
  }
}

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

/// Whose chapter it is, and how much of the file it holds.
class _SideAndLines extends StatelessWidget {
  const _SideAndLines({required this.chapter, required this.onSide});

  final Chapter chapter;
  final ValueChanged<Side> onSide;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      // A study chapter's board faces the way its own `[Orientation]` tag
      // says, which its row in the study list changes; the `// Color:` line
      // these buttons write belongs to a repertoire chapter and is not what
      // a study reads.
      if (chapter.game == null)
        _SideChoice(side: chapter.side, onChanged: onSide),
      if (chapter.game == null) const SizedBox(width: Space.s),
      Expanded(
        child: Text(
          _summary(chapter),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    ],
  );
}

/// Which side the chapter is played from, and the way to change it. It is
/// two things, so it is two buttons: the answer is always in front of the
/// user rather than behind a menu they have to open to read it.
class _SideChoice extends StatelessWidget {
  const _SideChoice({required this.side, required this.onChanged});

  final Side side;
  final ValueChanged<Side> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<Side>(
      segments: const [
        ButtonSegment(value: Side.white, label: Text('White')),
        ButtonSegment(value: Side.black, label: Text('Black')),
      ],
      selected: {side},
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onSelectionChanged: (chosen) => onChanged(chosen.first),
    );
  }
}

/// What the line under the name says: for one game of a file, who played it
/// and where; for a merged chapter, how much of the file it holds.
String _summary(Chapter chapter) =>
    chapter.game == null ? _lineCount(chapter) : _gameLine(chapter);

/// The players, the result and the event of the game on the board, in the
/// words a study chapter or a viewed game is known by. Empty parts are left
/// out rather than written as `?`.
String _gameLine(Chapter chapter) {
  final index = chapter.game!;
  if (index >= chapter.lines.length) return '';
  final game = summarizeGame(chapter.lines[index], index: index);
  return [
    game.title,
    if (game.result.isNotEmpty) game.result,
    if (game.setting.isNotEmpty) game.setting,
  ].join(' · ');
}

/// How many games of the file the chapter holds: the games merged into the
/// tree, then the ones left out and why, because a chapter that shows fewer
/// lines than the file has must say so.
String _lineCount(Chapter chapter) {
  final lines = chapter.gameCount == 1
      ? '1 line'
      : '${chapter.gameCount} lines';
  final skipped = chapter.skippedGames == 0
      ? ''
      : ', ${chapter.skippedGames} from another position';
  final unreadable = chapter.unreadableGames == 0
      ? ''
      : ', ${chapter.unreadableGames} could not be read';
  // A line this app will not write is one the user should hear about before
  // they try to edit it, not after the edit is refused.
  final protected = chapter.protectedGames == 0
      ? ''
      : ', ${chapter.protectedGames} cannot be edited here';
  return '$lines$skipped$unreadable$protected';
}

/// The last edit, taken back. Disabled when there is nothing to take back,
/// which is also true of a document nobody has edited yet.
class _UndoButton extends StatelessWidget {
  const _UndoButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed,
    icon: const Icon(Icons.undo, size: IconSize.action),
    tooltip: 'Undo (Ctrl+Z)',
    visualDensity: VisualDensity.compact,
  );
}

/// The save state in words. Only a failure and a conflict take a colour:
/// everything else is ordinary and reads as ordinary.
class _SaveLine extends StatelessWidget {
  const _SaveLine({required this.state});

  final SaveState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trouble =
        state is SaveFailed ||
        state is SaveConflict ||
        state is SaveStopped ||
        state is DocumentReadOnly;
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
        color: trouble ? theme.colorScheme.error : null,
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

/// Asks what to call the copy. Returns null when the user backs out.
Future<String?> showCopyNameDialog(BuildContext context, String suggestion) =>
    showDialog<String>(
      context: context,
      builder: (context) => _CopyNameDialog(suggestion: suggestion),
    );

class _CopyNameDialog extends StatefulWidget {
  const _CopyNameDialog({required this.suggestion});

  final String suggestion;

  @override
  State<_CopyNameDialog> createState() => _CopyNameDialogState();
}

class _CopyNameDialogState extends State<_CopyNameDialog> {
  late final _controller = TextEditingController(
    text: '${widget.suggestion} copy',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Save a copy'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        onSubmitted: (_) => _submit(),
        decoration: const InputDecoration(
          labelText: 'File name',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save a copy')),
      ],
    );
  }
}
