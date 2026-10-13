import '../../chess/pgn/chapter_line.dart';
import '../../chess/pgn/study_cleanup.dart';
import 'chapter_dialogs.dart';
import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chess/pgn/comment_text.dart';
import '../../chess/pgn/game_tree.dart';
import '../../chess/pgn/study.dart';
import '../../ui/status_bar.dart';
import '../../storage/chapter_files.dart';
import '../../ui/confirm_dialog.dart';
import '../../ui/name_dialog.dart';
import '../../ui/row_actions.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import '../../workspace/board_editor.dart';
import '../../workspace/document_session.dart';
import 'new_chapter_dialog.dart';
import 'studies.dart';
import 'study_commands.dart';
import 'study_chapter_list.dart';
import 'chapter_position_dialog.dart';
import 'study_import_dialog.dart';
import 'study_recovery_dialog.dart';

/// Opens one chapter of a study in the workspace.
typedef OpenChapter = void Function(ChapterRef study, int chapter);

/// A searchable study picker and a focused list of the current chapters.
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
    this.onTrain,
    this.trailing,
  });

  final Studies studies;
  final DocumentSession session;
  final OpenChapter onOpen;
  final VoidCallback? onTrain;

  /// What sits in the toolbar's corner: the host's toggle for the pane.
  final Widget? trailing;

  @override
  State<StudyPanel> createState() => _StudyPanelState();
}

class _StudyPanelState extends State<StudyPanel> {
  final _search = TextEditingController();
  bool _choosingStudy = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Studies get _studies => widget.studies;

  /// A change that did not happen says why in the window's status bar.
  void _say(String sentence) {
    if (!mounted) return;
    StatusScope.of(context)(sentence);
  }

  /// Shows what became of a change, and opens what it produced.
  ///
  /// Nothing happens when this panel is gone: a download that finishes after
  /// the user has left Study mode must not drive the workspace onto the
  /// study it fetched, over whatever they opened instead.
  void _became(StudyResult result) {
    if (!mounted) return;
    switch (result) {
      case StudyProblem(:final sentence):
        _say(sentence);
      case StudyDone(:final opened, :final chapter):
        if (opened != null) {
          setState(() => _choosingStudy = false);
          widget.onOpen(opened, chapter ?? 0);
        }
    }
  }

  Future<void> _newStudy() async {
    final name = await showNameDialog(
      context,
      title: 'New study',
      label: 'Study name',
      confirm: 'Create',
    );
    if (name == null || !mounted) return;
    _became(await _studies.create(name));
  }

  Future<void> _import() async {
    final result = await showStudyImport(
      context,
      _studies,
      append: _studies.open != null,
    );
    if (result != null && mounted) _became(result);
  }

  Future<void> _renameStudy() async {
    final study = _studies.open;
    if (study == null) return;
    final name = await showNameDialog(
      context,
      title: 'Rename study',
      label: 'Study name',
      confirm: 'Rename',
      initial: study.name,
    );
    if (name == null || !mounted) return;
    _became(await _studies.rename(study, name));
  }

  Future<void> _exportStudy() async {
    final study = _studies.open;
    if (study == null) return;
    final name = await showNameDialog(
      context,
      title: 'Save study PGN as',
      label: 'File name',
      confirm: 'Choose folder',
      initial: study.name,
    );
    if (name == null || !mounted) return;
    if (_studies.open != study) {
      _say('The open study changed. Export it again.');
      return;
    }
    _became(await _studies.exportPgn(name));
  }

  ChapterLine? _line(StudyChapter chapter) =>
      widget.session.chapter?.lines.elementAtOrNull(chapter.index);
  bool _same(StudyChapter chapter, ChapterLine line) =>
      mounted && identical(_line(chapter), line);
  Future<void> _tags(StudyChapter chapter) async {
    final line = _line(chapter);
    if (line == null) return;
    final values = await showStudyTags(context, line.tags);
    if (values == null || !_same(chapter, line)) return;
    _edited(setStudyTags(widget.session, chapter.index, values));
  }

  Future<void> _root(StudyChapter chapter) async {
    final line = _line(chapter);
    final tree = line?.tree;
    if (tree == null) return;
    final root = await showBoardEditor(
      context,
      initial: tree.rootFen,
      title: 'Set starting position',
    );
    if (root == null || !mounted || !_same(chapter, line!)) return;
    final count = studyContentCount(tree);
    if (count.moves > 0) {
      final yes = await confirmAction(
        context,
        title: 'Replace starting position?',
        message:
            'Replace the starting position of "${chapter.name}" and remove its ${count.moves} moves? This edit can be undone.',
        confirm: 'Replace position',
      );
      if (!yes || !_same(chapter, line)) return;
    }
    _edited(setStudyRoot(widget.session, chapter.index, root));
  }

  Future<void> _clean(StudyChapter chapter, {required bool annotations}) async {
    final line = _line(chapter);
    final tree = line?.tree;
    if (tree == null) return;
    final count = studyContentCount(tree);
    final yes = await confirmAction(
      context,
      title: annotations ? 'Clear annotations' : 'Clear variations',
      message: annotations
          ? 'Remove ${count.comments} comments and all glyphs and shapes from "${chapter.name}"? The moves stay.'
          : 'Remove ${count.sidelines} sideline moves and their annotations from "${chapter.name}"? The main line and its notes stay.',
      confirm: 'Clear',
    );
    if (!yes || !_same(chapter, line!)) return;
    _edited(
      clearStudyContent(
        widget.session,
        chapter.index,
        annotations: annotations,
      ),
    );
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

  Future<void> _copy(Future<String?> pgn) async {
    final text = await pgn;
    if (!mounted) return;
    if (text == null) {
      _say('There is nothing to copy.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> _newChapter() async {
    final wanted = await showNewChapterDialog(context);
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

  Future<void> _moveTo(StudyChapter chapter) async {
    final line = _line(chapter);
    if (line == null) return;
    final to = await showChapterPosition(
      context,
      chapter.ordinal,
      _studies.chapters.length,
    );
    if (to == null || !_same(chapter, line)) return;
    _edited(
      moveStudyChapter(
        widget.session,
        index: chapter.index,
        by: to - chapter.ordinal,
      ),
    );
  }

  ChapterActions _actionsFor(StudyChapter chapter) => (
    rename: () => _renameChapter(chapter),
    tags: () => unawaited(_tags(chapter)),
    root: () => unawaited(_root(chapter)),
    clearAnnotations: () => unawaited(_clean(chapter, annotations: true)),
    clearVariations: () => unawaited(_clean(chapter, annotations: false)),
    face: (side) => _edited(
      setStudyChapterOrientation(
        widget.session,
        index: chapter.index,
        orientation: side,
      ),
    ),
    move: (by) =>
        _edited(moveStudyChapter(widget.session, index: chapter.index, by: by)),
    copyPgn: () => _copy(_studies.pgnOfChapter(chapter.index)),
    remove: () => _deleteChapter(chapter),
    moveTo: () => _moveTo(chapter),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_studies, widget.session]),
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Toolbar(
            currentName: !_choosingStudy ? _studies.open?.name : null,
            onChooseStudy: () => setState(() => _choosingStudy = true),
            busy: _studies.busy,
            hasOpenStudy: _studies.open != null,
            search: _search,
            onSearch: _studies.search,
            onNewStudy: _newStudy,
            onImport: _import,
            onRenameStudy: () => unawaited(_renameStudy()),
            onExportStudy: () => unawaited(_exportStudy()),
            onRetrySave: _studies.canRetrySave
                ? () => unawaited(_studies.retrySave().then(_became))
                : null,
            onRetryRename: _studies.canRetryRename
                ? () => unawaited(_studies.retryRename().then(_became))
                : null,
            onCopyStudy: () => _copy(_studies.pgnOfOpenStudy()),
            onDeleteStudy: () {
              final open = _studies.open;
              if (open != null) unawaited(_deleteStudy(open));
            },
            onNewChapter: _newChapter,
            onTrain: widget.onTrain,
            trailing: widget.trailing,
          ),
          Expanded(child: _body(context)),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _studies.busy
                  ? null
                  : () => showStudyRecovery(context, _studies),
              child: Text(
                _studies.canRetryRestore
                    ? 'Deleted studies · restore pending'
                    : 'Deleted studies',
              ),
            ),
          ),
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
    final study = _studies.open;
    if (study != null && !_choosingStudy) {
      return StudyChapterList(
        key: ValueKey(study.path),
        chapters: _studies.chapters,
        active: _studies.openChapter,
        busy: _studies.busy,
        onOpen: (index) => widget.onOpen(study, index),
        actionsFor: _actionsFor,
        onReorder: (from, to) => _edited(
          moveStudyChapter(widget.session, index: from, by: to - from),
        ),
      );
    }
    if (_studies.studies.isEmpty) {
      return const _Message(
        'No studies yet\nCreate one, or import a Lichess study.',
      );
    }
    if (_studies.visible.isEmpty) {
      return _Message('Nothing matches "${_studies.query}".');
    }
    // Build each study row when it scrolls into view.
    final rows = <WidgetBuilder>[];
    for (final study in _studies.visible) {
      final open = study == _studies.open;
      rows.add(
        (_) => StudyRow(
          study: study,
          open: open,
          busy: _studies.busy,
          onOpen: () {
            setState(() => _choosingStudy = false);
            widget.onOpen(study, 0);
          },
          onCopyPgn: () => _copy(_studies.pgnOfOpenStudy()),
          onDelete: () => _deleteStudy(study),
        ),
      );
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
    this.currentName,
    required this.onChooseStudy,
    required this.hasOpenStudy,
    required this.search,
    required this.onSearch,
    required this.onNewStudy,
    required this.onImport,
    required this.onRenameStudy,
    required this.onExportStudy,
    this.onRetryRename,
    this.onRetrySave,
    required this.onCopyStudy,
    required this.onDeleteStudy,
    required this.onNewChapter,
    required this.onTrain,
    required this.trailing,
  });

  final bool busy;
  final bool hasOpenStudy;
  final String? currentName;
  final VoidCallback onChooseStudy;
  final TextEditingController search;
  final ValueChanged<String> onSearch;
  final VoidCallback onNewStudy;
  final VoidCallback onImport;
  final VoidCallback onRenameStudy, onExportStudy;
  final VoidCallback? onRetryRename, onRetrySave;
  final VoidCallback onCopyStudy;
  final VoidCallback onDeleteStudy;
  final VoidCallback onNewChapter;
  final VoidCallback? onTrain;
  final Widget? trailing;

  /// Making and removing whole studies, and taking one away as text. The
  /// two that need a study open are off until one is.
  List<Widget> get _actions => [
    rowAction('New study…', onNewStudy, busy: busy, icon: Icons.add),
    rowAction(
      'Import chapters…',
      onImport,
      busy: busy,
      icon: Icons.file_open_outlined,
    ),
    rowAction(
      'Rename study…',
      onRenameStudy,
      busy: busy || !hasOpenStudy,
      icon: Icons.edit_outlined,
    ),
    rowAction(
      'Save study PGN as…',
      onExportStudy,
      busy: busy || !hasOpenStudy,
      icon: Icons.save_outlined,
    ),
    if (onRetrySave != null)
      rowAction('Retry study save', onRetrySave!, busy: busy),
    if (onRetryRename != null)
      rowAction('Retry rename', onRetryRename!, busy: busy),
    rowAction(
      'Copy study PGN',
      onCopyStudy,
      busy: busy || !hasOpenStudy,
      icon: Icons.content_copy,
    ),
    rowAction(
      'Delete study…',
      onDeleteStudy,
      busy: busy || !hasOpenStudy,
      icon: Icons.delete_outline,
    ),
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
              if (currentName != null)
                IconButton(
                  tooltip: 'All studies',
                  onPressed: onChooseStudy,
                  icon: const Icon(Icons.arrow_back, size: IconSize.menu),
                  visualDensity: VisualDensity.compact,
                ),
              // Room for the buttons first: a narrow pane cuts the label,
              // which otherwise has all the row leaves it.
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        currentName ?? 'Your studies',
                        style: Theme.of(context).textTheme.labelSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: Space.xs),
                    RowActions(tooltip: 'Study actions', children: _actions),
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: Space.xs),
          if (currentName == null)
            SearchField(
              controller: search,
              hint: 'Search studies',
              onChanged: onSearch,
            ),
          const SizedBox(height: Space.s),
          if (!hasOpenStudy)
            FilledButton(
              onPressed: busy ? null : onNewStudy,
              child: const Text('New study'),
            ),
          TextButton(
            onPressed: busy ? null : onImport,
            child: const Text('Import…'),
          ),
          if (hasOpenStudy && onTrain != null)
            OutlinedButton(
              onPressed: busy ? null : onTrain,
              child: const Text('Train study'),
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
    return Semantics(
      selected: open,
      child: Material(
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
                    child: Tooltip(
                      message: study.name,
                      child: Text(study.name, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  RowActions(
                    children: [
                      // Only the open study's text is in hand; another one
                      // would have to be read from disk first.
                      rowAction(
                        'Copy study PGN',
                        onCopyPgn,
                        busy: busy || !open,
                        icon: Icons.content_copy,
                      ),
                      rowAction(
                        'Delete study…',
                        onDelete,
                        busy: busy,
                        icon: Icons.delete_outline,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What a right-click on a move offers in a study: where training starts
/// asking, and where it stops.
///
/// A marker is a token in the move's comment, so it travels with the chapter
/// through an export, an import and anyone else's reader. The words on the
/// move are not touched, and each entry reads as what pressing it does.
List<Widget> quizMenuItems(DocumentSession session, NodePath path) {
  if (path.isRoot) return const [];
  final comment = session.tree?.nodeAt(path)?.comment;
  final starts = hasToken(comment, quizStartMarker);
  final ends = hasToken(comment, quizEndMarker);
  return [
    _item(
      starts ? 'Do not start a quiz here' : 'Start quiz from this move',
      () => session.setMarker(path, quizStartMarker, on: !starts),
    ),
    _item(
      ends ? 'Do not end a quiz here' : 'End quiz after this move',
      () => session.setMarker(path, quizEndMarker, on: !ends),
    ),
  ];
}

MenuItemButton _item(String label, VoidCallback run) =>
    MenuItemButton(onPressed: run, child: Text(label));
