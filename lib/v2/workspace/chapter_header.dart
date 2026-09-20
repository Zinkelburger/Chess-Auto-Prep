import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../chess/pgn/chapter.dart';
import '../chess/pgn/comment_edits.dart';
import '../storage/chapter_files.dart';
import '../ui/theme.dart';
import 'document_saver.dart';
import 'save_state.dart';
import 'document_session.dart';

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
        UndoRefused() => 'Nothing to undo right now',
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
              Text(_summary(chapter), style: text.bodySmall),
              const SizedBox(height: Space.xs),
              Row(
                children: [
                  Expanded(child: _SaveLine(state: widget.saver.state)),
                  _UndoButton(onPressed: widget.saver.canUndo ? _undo : null),
                ],
              ),
              if (widget.saver.state is SaveConflict ||
                  widget.saver.state is SaveStopped)
                _ConflictActions(onReload: _reload, onSaveCopy: _saveCopy),
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
String _refusalNotice(CommentRefused refusal) => switch (refusal) {
  GameNotWhole() =>
    'That line could not be read in full, so it is left as it is. Edit it '
        'in the old app.',
  CommentUnwritable(:final reason) =>
    'The note was not saved: $reason. Take it out and try again.',
};

/// Whose chapter it is and how many games of the file it holds: the games
/// merged into the tree, then the ones left out and why, because a chapter
/// that shows fewer lines than the file has must say so.
String _summary(Chapter chapter) {
  final side = chapter.side == Side.white ? 'White' : 'Black';
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
  return '$side · $lines$skipped$unreadable$protected';
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
              'stopped. Nothing was written and the document is back as the '
              'file has it.',
        DocumentReadOnly() =>
          'This file is not UTF-8, so it opened to read. Open and save it in '
              'the old app to convert it, then edit it here.',
      },
      style: theme.textTheme.bodySmall?.copyWith(
        color: trouble ? theme.colorScheme.error : null,
      ),
    );
  }
}

class _ConflictActions extends StatelessWidget {
  const _ConflictActions({required this.onReload, required this.onSaveCopy});

  final VoidCallback onReload;
  final VoidCallback onSaveCopy;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        TextButton(onPressed: onReload, child: const Text('Reload')),
        const SizedBox(width: Space.s),
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
