import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chess/pgn/study.dart';
import '../../storage/chapter_files.dart';
import '../../ui/confirm_dialog.dart';
import '../../ui/name_dialog.dart';
import '../../ui/row_actions.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import '../../workspace/document_session.dart';
import 'new_chapter_dialog.dart';
import 'studies.dart';
import 'study_commands.dart';

/// Opens one chapter of a study in the workspace.
typedef OpenChapter = void Function(ChapterRef study, int chapter);

/// The studies, searchable, with the chapters of the open one under it.
///
/// Everything on this panel is one of two things: an operation on a whole
/// file, which belongs to [Studies], or an edit to the chapters of the file
/// the workspace has open, which is a command over the session. The panel
/// itself keeps only what the user has typed into the search field.
class StudyPanel extends StatefulWidget {
  const StudyPanel({
    super.key,
    required this.studies,
    required this.session,
    required this.onOpen,
    this.trailing,
  });

  final Studies studies;
  final DocumentSession session;
  final OpenChapter onOpen;

  /// What sits in the toolbar's corner: the host's toggle for the pane.
  final Widget? trailing;

  @override
  State<StudyPanel> createState() => _StudyPanelState();
}

class _StudyPanelState extends State<StudyPanel> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Studies get _studies => widget.studies;

  void _say(String sentence) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(sentence)));
  }

  /// Shows what became of a change, and opens what it produced.
  ///
  /// Nothing happens when this panel is gone: a download that finishes after
  /// the user has left Study mode must not drive the workspace onto the
  /// study it fetched, over whatever they opened instead.
  void _became(StudyResult result, {String? done}) {
    if (!mounted) return;
    switch (result) {
      case StudyProblem(:final sentence):
        _say(sentence);
      case StudyDone(:final opened):
        if (opened != null) widget.onOpen(opened, 0);
        if (done != null) _say(done);
    }
  }

  Future<void> _newStudy() async {
    final name = await showNameDialog(
      context,
      title: 'New study',
      label: 'Study name',
      hint: 'Opening ideas',
      confirm: 'Create',
    );
    if (name == null || !mounted) return;
    _became(await _studies.create(name));
  }

  Future<void> _import() async {
    final url = await showImportStudyDialog(
      context,
      describe: _studies.linkDescription,
    );
    if (url == null || !mounted) return;
    _became(await _studies.importFromUrl(url), done: 'Study imported.');
  }

  Future<void> _deleteStudy(ChapterRef study) async {
    final yes = await confirmAction(
      context,
      title: 'Delete study "${study.name}"?',
      message:
          'The PGN file, with every chapter in it, will be moved to Chess '
          'Auto Prep recovery storage.',
      confirm: 'Delete',
    );
    if (!yes || !mounted) return;
    _became(await _studies.delete(study));
  }

  Future<void> _copy(Future<String?> pgn, String what) async {
    final text = await pgn;
    if (!mounted) return;
    if (text == null) {
      _say('There is nothing to copy.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _say('$what copied to the clipboard.');
  }

  Future<void> _newChapter() async {
    final wanted = await showNewChapterDialog(
      context,
      suggested: nextChapterName(_studies.chapters),
    );
    if (wanted == null || !mounted) return;
    _edited(
      addStudyChapter(
        widget.session,
        name: wanted.name,
        orientation:
            wanted.orientation ??
            (wanted.root.whiteToMove ? Side.white : Side.black),
        root: wanted.root,
      ),
    );
  }

  Future<void> _renameChapter(StudyChapter chapter) async {
    final name = await showNameDialog(
      context,
      title: 'Rename chapter',
      label: 'Chapter name',
      confirm: 'Rename',
      initial: chapter.name,
    );
    if (name == null || name == chapter.name || !mounted) return;
    _edited(
      renameStudyChapter(widget.session, index: chapter.index, name: name),
    );
  }

  Future<void> _deleteChapter(StudyChapter chapter) async {
    if (_studies.chapters.length <= 1) {
      _say('A study needs at least one chapter.');
      return;
    }
    final yes = await confirmAction(
      context,
      title: 'Delete chapter "${chapter.name}"?',
      message:
          'Its moves and comments go with it. The rest of the study is '
          'untouched.',
      confirm: 'Delete',
    );
    if (!yes || !mounted) return;
    _edited(deleteStudyChapter(widget.session, index: chapter.index));
  }

  /// A chapter edit says nothing when it happened, and one sentence when it
  /// did not.
  void _edited(String? refusal) {
    if (refusal != null) _say(refusal);
  }

  ChapterActions _actionsFor(StudyChapter chapter) => (
    rename: () => _renameChapter(chapter),
    face: (side) => _edited(
      setStudyChapterOrientation(
        widget.session,
        index: chapter.index,
        orientation: side,
      ),
    ),
    move: (by) =>
        _edited(moveStudyChapter(widget.session, index: chapter.index, by: by)),
    copyPgn: () => _copy(_studies.pgnOfChapter(chapter.index), 'Chapter PGN'),
    remove: () => _deleteChapter(chapter),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_studies, widget.session]),
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Toolbar(
            busy: _studies.busy,
            hasOpenStudy: _studies.open != null,
            search: _search,
            onSearch: _studies.search,
            onNewStudy: _newStudy,
            onImport: _import,
            onCopyStudy: () => _copy(_studies.pgnOfOpenStudy(), 'Study PGN'),
            onDeleteStudy: () {
              final open = _studies.open;
              if (open != null) unawaited(_deleteStudy(open));
            },
            onNewChapter: _newChapter,
            trailing: widget.trailing,
          ),
          Expanded(child: _body(context)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) => switch (_studies.state) {
    StudiesLoading() => const Center(child: CircularProgressIndicator()),
    StudiesLoadFailed() => _Failure(onRetry: _studies.refresh),
    StudiesLoaded() => _listed(context),
  };

  Widget _listed(BuildContext context) {
    if (_studies.studies.isEmpty) {
      return const _Message(
        'No studies yet\nCreate one, or import a Lichess study.',
      );
    }
    if (_studies.visible.isEmpty) {
      return _Message('Nothing matches "${_studies.query}".');
    }
    // A study list and an open study's chapters, flattened, each row made
    // when it scrolls into view.
    final rows = <WidgetBuilder>[];
    for (final study in _studies.visible) {
      final open = study == _studies.open;
      rows.add(
        (_) => StudyRow(
          study: study,
          open: open,
          busy: _studies.busy,
          onOpen: () => widget.onOpen(study, 0),
          onCopyPgn: () => _copy(_studies.pgnOfOpenStudy(), 'Study PGN'),
          onDelete: () => _deleteStudy(study),
        ),
      );
      if (!open) continue;
      for (final chapter in _studies.chapters) {
        rows.add(
          (_) => ChapterRow(
            chapter: chapter,
            open: chapter.index == _studies.openChapter,
            busy: _studies.busy,
            onOpen: () => widget.onOpen(study, chapter.index),
            actions: _actionsFor(chapter),
          ),
        );
      }
    }
    return ListView.builder(
      itemCount: rows.length,
      itemBuilder: (context, index) => rows[index](context),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.busy,
    required this.hasOpenStudy,
    required this.search,
    required this.onSearch,
    required this.onNewStudy,
    required this.onImport,
    required this.onCopyStudy,
    required this.onDeleteStudy,
    required this.onNewChapter,
    required this.trailing,
  });

  final bool busy;
  final bool hasOpenStudy;
  final TextEditingController search;
  final ValueChanged<String> onSearch;
  final VoidCallback onNewStudy;
  final VoidCallback onImport;
  final VoidCallback onCopyStudy;
  final VoidCallback onDeleteStudy;
  final VoidCallback onNewChapter;
  final Widget? trailing;

  /// Making and removing whole studies, and taking one away as text. The
  /// two that need a study open are off until one is.
  List<Widget> get _actions => [
    rowAction('New study…', onNewStudy, busy: busy),
    rowAction('Import from URL…', onImport, busy: busy),
    rowAction('Copy study PGN', onCopyStudy, busy: busy || !hasOpenStudy),
    rowAction('Delete study…', onDeleteStudy, busy: busy || !hasOpenStudy),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.s, Space.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              // Room for the buttons first: a narrow pane cuts the label.
              Flexible(
                child: Text(
                  'Your studies',
                  style: Theme.of(context).textTheme.labelSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: Space.xs),
              RowActions(tooltip: 'Study actions', children: _actions),
              const Spacer(),
              ?trailing,
            ],
          ),
          const SizedBox(height: Space.xs),
          SearchField(
            controller: search,
            hint: 'Search studies',
            onChanged: onSearch,
          ),
          if (hasOpenStudy)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: busy ? null : onNewChapter,
                icon: const Icon(Icons.add, size: IconSize.menu),
                label: const Text('New chapter'),
              ),
            ),
        ],
      ),
    );
  }
}

class _Failure extends StatelessWidget {
  const _Failure({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Space.l),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Could not read your studies folder. Please try again.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: Space.s),
          FilledButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Space.l),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}

/// One study in the list. The open one is highlighted and its chapters are
/// listed under it.
class StudyRow extends StatelessWidget {
  const StudyRow({
    super.key,
    required this.study,
    required this.open,
    required this.busy,
    required this.onOpen,
    required this.onCopyPgn,
    required this.onDelete,
  });

  final ChapterRef study;

  /// This is the study the workspace has open.
  final bool open;

  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onCopyPgn;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: open ? scheme.surfaceContainerHighest : Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.s, 0, Space.xs, 0),
          child: SizedBox(
            height: listRowHeight,
            child: Row(
              children: [
                Expanded(
                  child: Text(study.name, overflow: TextOverflow.ellipsis),
                ),
                RowActions(
                  children: [
                    // Only the open study's text is in hand; another one
                    // would have to be read from disk first.
                    rowAction('Copy study PGN', onCopyPgn, busy: busy || !open),
                    rowAction('Delete study…', onDelete, busy: busy),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What a chapter row's menu can ask for.
typedef ChapterActions = ({
  VoidCallback rename,
  void Function(Side orientation) face,
  void Function(int by) move,
  VoidCallback copyPgn,
  VoidCallback remove,
});

/// One chapter of the open study: its place in the file, its name, and the
/// operations that change it.
class ChapterRow extends StatelessWidget {
  const ChapterRow({
    super.key,
    required this.chapter,
    required this.open,
    required this.busy,
    required this.onOpen,
    required this.actions,
  });

  final StudyChapter chapter;

  /// This is the chapter on the board.
  final bool open;

  final bool busy;
  final VoidCallback onOpen;
  final ChapterActions actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: open ? theme.colorScheme.surfaceContainerHighest : null,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.l, 0, Space.xs, 0),
          child: SizedBox(
            height: listRowHeight,
            child: Row(
              children: [
                SizedBox(
                  width: Space.l + Space.xs,
                  child: Text(
                    '${chapter.ordinal}',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                Expanded(
                  child: Text(chapter.name, overflow: TextOverflow.ellipsis),
                ),
                RowActions(
                  tooltip: 'Chapter actions',
                  children: [
                    rowAction('Rename…', actions.rename, busy: busy),
                    rowAction(
                      'Face White',
                      () => actions.face(Side.white),
                      busy: busy || chapter.orientation == Side.white,
                    ),
                    rowAction(
                      'Face Black',
                      () => actions.face(Side.black),
                      busy: busy || chapter.orientation == Side.black,
                    ),
                    rowAction('Move up', () => actions.move(-1), busy: busy),
                    rowAction('Move down', () => actions.move(1), busy: busy),
                    rowAction('Copy chapter PGN', actions.copyPgn, busy: busy),
                    rowAction('Delete chapter…', actions.remove, busy: busy),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks for a Lichess study link and answers what the user typed, or null
/// when they backed out.
///
/// [describe] says what a link is recognised as, or null when it is not one
/// the app can fetch; it comes from the owner, so this dialog knows nothing
/// about the service. What was recognised is echoed back on a line that is
/// always there, so it appearing does not push the button out from under the
/// pointer, and only a recognised link enables the button. The download
/// itself, and anything that goes wrong with it, belongs to the panel.
Future<String?> showImportStudyDialog(
  BuildContext context, {
  required String? Function(String input) describe,
}) => showDialog<String>(
  context: context,
  builder: (context) => _ImportDialog(describe: describe),
);

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.describe});

  final String? Function(String input) describe;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _url = TextEditingController();
  String? _recognised;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  void _typed(String text) {
    if (!mounted) return;
    setState(() => _recognised = widget.describe(text));
  }

  void _import() {
    if (_recognised != null) Navigator.of(context).pop(_url.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('Import from URL'),
      content: SizedBox(
        width: nameDialogWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _url,
              autofocus: true,
              onChanged: _typed,
              onSubmitted: (_) => _import(),
              decoration: const InputDecoration(
                labelText: 'Study link',
                hintText: 'lichess.org/study/abcd1234',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: Space.s),
            Text(_echo, style: text.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _recognised == null ? null : _import,
          child: const Text('Import'),
        ),
      ],
    );
  }

  String get _echo {
    if (_recognised case final recognised?) return recognised;
    if (_url.text.trim().isEmpty) {
      return 'Accepts lichess.org/study/<id> and '
          'lichess.org/study/<id>/<chapter>.';
    }
    return 'Not a Lichess study link.';
  }
}
