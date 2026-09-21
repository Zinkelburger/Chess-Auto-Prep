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
import 'import_dialog.dart';
import 'new_chapter_dialog.dart';
import 'studies.dart';
import 'study_commands.dart';
import 'study_rows.dart';

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
  });

  final Studies studies;
  final DocumentSession session;
  final OpenChapter onOpen;

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
  void _became(StudyResult result, {String? done}) {
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
    final rows = <Widget>[];
    for (final study in _studies.visible) {
      final open = study == _studies.open;
      rows.add(
        StudyRow(
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
          ChapterRow(
            chapter: chapter,
            open: chapter.index == _studies.openChapter,
            busy: _studies.busy,
            onOpen: () => widget.onOpen(study, chapter.index),
            actions: _actionsFor(chapter),
          ),
        );
      }
    }
    return ListView(children: rows);
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
              Expanded(
                child: Text(
                  'Your studies',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              RowActions(tooltip: 'Study actions', children: _actions),
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
