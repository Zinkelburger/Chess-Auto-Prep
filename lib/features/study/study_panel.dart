import '../../chess/pgn/chapter_line.dart';
import '../../chess/pgn/study_cleanup.dart';
import 'chapter_dialogs.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chess/pgn/study.dart';
import '../../ui/status_bar.dart';
import '../../storage/chapter_files.dart';
import '../../ui/confirm_dialog.dart';
import '../../ui/name_dialog.dart';
import '../../ui/row_actions.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import '../../workspace/board/board_editor.dart';
import '../../workspace/document/document_session.dart';
import 'studies.dart';
import 'studies_state.dart';
import 'study_commands.dart';
import 'study_chapter_list.dart';
import 'chapter_position_dialog.dart';
import 'study_actions.dart';
import 'study_recovery_dialog.dart';
import '../../ui/list_message.dart';
import '../../ui/list_row.dart';
import '../../ui/app_icons.dart';
import '../../ui/tool_button.dart';

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
    this.onLichessLogin,
    this.trailing,
  });

  final Studies studies;
  final DocumentSession session;
  final OpenChapter onOpen;
  final VoidCallback? onTrain;

  /// The Lichess login, for a send that needs one; true once logged in.
  final Future<bool> Function(BuildContext)? onLichessLogin;

  /// What sits in the toolbar's corner: the host's toggle for the pane.
  final Widget? trailing;

  @override
  State<StudyPanel> createState() => _StudyPanelState();
}

class _StudyPanelState extends State<StudyPanel> {
  final _search = TextEditingController();

  /// The study that was open when the list of studies was asked for: the
  /// list shows until another study opens, from here or the Actions menu.
  String? _choosingFrom;
  bool get _choosingStudy =>
      _choosingFrom != null && _choosingFrom == _studies.open?.path;

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
          setState(() => _choosingFrom = null);
          widget.onOpen(opened, chapter ?? 0);
        }
    }
  }

  Future<void> _newStudy() => newStudy(context, _studies, _became);

  Future<void> _import() => importChapters(context, _studies, _became);

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
      title: 'Export study PGN',
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

  Future<void> _sendToLichess() => sendStudyToLichess(
    context,
    _studies,
    widget.session,
    onLogIn: widget.onLichessLogin,
  );

  ChapterLine? _line(StudyChapter chapter) =>
      widget.session.chapter?.lines.elementAtOrNull(chapter.index);
  bool _same(StudyChapter chapter, ChapterLine line) =>
      mounted && identical(_line(chapter), line);
  Future<void> _tags(StudyChapter chapter) async {
    final line = _line(chapter);
    if (line == null) return;
    final study = widget.session.chapter;
    final values = await showStudyTags(
      context,
      line.tags,
      study: study == null ? '' : studyNameOf(study),
    );
    if (values == null || !_same(chapter, line)) return;
    _edited(setStudyTags(widget.session, chapter.index, values));
    // A chapter still called `Chapter N` takes its players' names, as
    // Lichess names a game it imports.
    final white = values['White']?.trim() ?? '';
    final black = values['Black']?.trim() ?? '';
    if (_numbered.hasMatch(chapter.name) &&
        white.isNotEmpty &&
        black.isNotEmpty) {
      _edited(
        renameStudyChapter(
          widget.session,
          index: chapter.index,
          name: '$white - $black',
        ),
      );
    }
  }

  static final _numbered = RegExp(r'^Chapter \d+$');

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
      title: annotations ? 'Clear annotations?' : 'Clear variations?',
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
      title: 'Delete study “${study.name}”?',
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

  Future<void> _newChapter() => newStudyChapter(context, widget.session, _say);

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
      title: 'Delete chapter “${chapter.name}”?',
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
            onChooseStudy: () =>
                setState(() => _choosingFrom = _studies.open?.path),
            busy: _studies.busy,
            hasOpenStudy: _studies.open != null,
            search: _search,
            onSearch: _studies.search,
            onNewStudy: _newStudy,
            onImport: _import,
            onRenameStudy: () => unawaited(_renameStudy()),
            onExportStudy: () => unawaited(_exportStudy()),
            onSendToLichess: _studies.sender == null
                ? null
                : () => unawaited(_sendToLichess()),
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
    StudiesLoading() => const ListMessage.loading('Reading studies…'),
    StudiesLoadFailed() => ListMessage(
      'Could not read your studies folder.',
      action: OutlinedButton(
        onPressed: _studies.refresh,
        child: const Text('Try again'),
      ),
    ),
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
      return const ListMessage('No studies yet.');
    }
    if (_studies.visible.isEmpty) {
      return ListMessage('Nothing matches "${_studies.query}".');
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
            setState(() => _choosingFrom = null);
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
    this.onSendToLichess,
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

  /// Null where the app cannot write to Lichess.
  final VoidCallback? onSendToLichess;
  final VoidCallback? onRetryRename, onRetrySave;
  final VoidCallback onCopyStudy;
  final VoidCallback onDeleteStudy;
  final VoidCallback onNewChapter;
  final VoidCallback? onTrain;
  final Widget? trailing;

  /// Making and removing whole studies, and taking one away as text. The
  /// two that need a study open are off until one is.
  List<Widget> get _actions => [
    rowAction('New study…', onNewStudy, busy: busy, icon: AppIcons.add),
    rowAction(
      'Rename study…',
      onRenameStudy,
      busy: busy || !hasOpenStudy,
      icon: AppIcons.edit,
    ),
    rowAction(
      'Export study PGN…',
      onExportStudy,
      busy: busy || !hasOpenStudy,
      icon: AppIcons.saveCopy,
    ),
    // A study has one write pending at a time: its save or its rename.
    if (onRetrySave ?? onRetryRename case final retry?)
      rowAction('Retry save', retry, busy: busy),
    rowAction(
      'Copy study PGN',
      onCopyStudy,
      busy: busy || !hasOpenStudy,
      icon: AppIcons.copy,
    ),
    rowAction(
      'Delete study…',
      onDeleteStudy,
      busy: busy || !hasOpenStudy,
      icon: AppIcons.delete,
    ),
  ];

  /// Lichess in and out, side by side: what came in goes back the same
  /// way.
  Widget _transfers() => Wrap(
    alignment: WrapAlignment.spaceEvenly,
    children: [
      TextButton.icon(
        onPressed: busy ? null : onImport,
        icon: const Icon(AppIcons.open, size: IconSize.action),
        label: const Text('Import chapters…'),
      ),
      if (hasOpenStudy && onSendToLichess != null)
        TextButton.icon(
          onPressed: busy ? null : onSendToLichess,
          icon: const Icon(AppIcons.send, size: IconSize.action),
          label: const Text('Send to Lichess…'),
        ),
    ],
  );

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
                ToolButton(
                  icon: AppIcons.back,
                  tooltip: 'Back to studies',
                  onPressed: onChooseStudy,
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
            FilledButton.icon(
              onPressed: busy ? null : onNewStudy,
              icon: const Icon(AppIcons.add, size: IconSize.action),
              label: const Text('New study…'),
            ),
          _transfers(),
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
                icon: const Icon(AppIcons.add, size: IconSize.action),
                label: const Text('New chapter…'),
              ),
            ),
        ],
      ),
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
  Widget build(BuildContext context) => ListRow(
    selected: open,
    onTap: onOpen,
    padding: const EdgeInsets.fromLTRB(Space.s, 0, Space.xs, 0),
    menu: [
      // Only the open study's text is in hand; another one would have to be
      // read from disk first.
      rowAction(
        'Copy study PGN',
        onCopyPgn,
        busy: busy || !open,
        icon: AppIcons.copy,
      ),
      rowAction('Delete study…', onDelete, busy: busy, icon: AppIcons.delete),
    ],
    child: Tooltip(
      message: study.name,
      child: Text(study.name, overflow: TextOverflow.ellipsis),
    ),
  );
}
