import 'dart:async';

import 'package:flutter/material.dart';

import '../features/library/chapter_outline.dart';
import '../features/library/library.dart';
import '../features/library/library_panel.dart';
import '../features/library/outline_panel.dart';
import '../features/study/quiz_menu.dart';
import '../features/study/studies.dart';
import '../features/study/study_panel.dart';
import '../storage/chapter_files.dart';
import '../ui/theme.dart';
import '../workspace/document_saver.dart';
import '../workspace/document_session.dart';
import '../workspace/session_results.dart';
import '../workspace/engine_analysis.dart';
import '../workspace/workspace_keys.dart';
import '../workspace/workspace_view.dart';
import 'exit_guard.dart';

/// The window: a top bar with the mode menu, the library on the left and the
/// workspace filling the rest. Opening a chapter from the library into the
/// workspace is the one cross-feature request, and it is handled here.
class Shell extends StatefulWidget {
  const Shell({
    super.key,
    required this.library,
    required this.studies,
    required this.outline,
    required this.session,
    required this.saver,
    required this.analysis,
    required this.leaving,
  });

  final Library library;
  final Studies studies;
  final ChapterOutline outline;
  final DocumentSession session;
  final DocumentSaver saver;
  final EngineAnalysis analysis;

  /// Asked before another document takes the screen, so words the file
  /// never took are not carried off it without the user saying so.
  final ExitGuard leaving;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  String? _error;
  var _mode = Mode.repertoires;

  /// Switching mode swaps the left column and nothing else: the same board,
  /// the same document and the same draft stay where they are. A study
  /// chapter opened from the study list is the same session on one game of
  /// its file.
  void _switchTo(Mode mode) {
    if (!mounted || mode == _mode) return;
    setState(() => _mode = mode);
    if (mode == Mode.study) unawaited(widget.studies.refresh());
  }

  /// The session opens the file; this only says what came of it. An open
  /// a later click overtook has nothing to say, so it says nothing.
  ///
  /// Opening a document takes the saver off the one that is open, and a
  /// draft it never wrote goes with it, so the user is asked first — the
  /// same question the closing window asks. When they answered it by saving
  /// a copy, the bar above says where those words went.
  Future<void> _open(ChapterRef ref, {int? game}) async {
    // Clicking the chapter that is already open is not leaving it.
    if (ref == widget.session.source && game == widget.session.game) return;
    if (!await widget.leaving.mayLeaveDocument()) return;
    if (!mounted) return;
    final copy = widget.leaving.lastCopy;
    widget.leaving.lastCopy = null;
    final result = await widget.session.open(ref, game: game);
    if (!mounted) return;
    switch (result) {
      case OpenOvertaken():
        return;
      case DocumentOpened():
        setState(() => _error = copy == null ? null : 'Saved a copy as $copy');
      case OpenFailed(:final reason):
        setState(() => _error = reason);
    }
  }

  Widget _leftColumn() => switch (_mode) {
    Mode.repertoires => ListenableBuilder(
      listenable: widget.session,
      builder: (context, _) => LibraryPanel(
        library: widget.library,
        selected: widget.session.source,
        onOpen: _open,
      ),
    ),
    Mode.study => StudyPanel(
      studies: widget.studies,
      session: widget.session,
      onOpen: (study, chapter) => unawaited(_open(study, game: chapter)),
    ),
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _TopBar(mode: _mode, onMode: _switchTo),
          const Divider(height: 1),
          if (_error case final error?) _ErrorBar(error),
          Expanded(
            child: WorkspaceKeys(session: widget.session, child: _columns()),
          ),
        ],
      ),
    );
  }

  /// The outline is a repertoire chapter's lines, so it is there only when
  /// a chapter that is a whole file is open. A study chapter is one game of
  /// its file, its chapters are already in its own left column, and the line
  /// operations do not mean the same thing there — so it has no outline,
  /// whichever mode the user switches to.
  Widget _outlineColumn() {
    if (widget.session.source == null || widget.session.game != null) {
      return const SizedBox.shrink();
    }
    return _OutlineColumn(
      outline: widget.outline,
      library: widget.library,
      session: widget.session,
      onOpen: _open,
    );
  }

  /// The columns the mode puts side by side, under one set of keys: the
  /// mode's own list, the outline when a repertoire chapter is open, and the
  /// workspace filling the rest.
  Widget _columns() {
    return Row(
      children: [
        SizedBox(
          width: _mode == Mode.study ? studyPanelWidth : libraryPanelWidth,
          child: _leftColumn(),
        ),
        const VerticalDivider(width: 1),
        ListenableBuilder(
          listenable: widget.session,
          builder: (context, _) => _outlineColumn(),
        ),
        Expanded(
          child: WorkspaceView(
            session: widget.session,
            saver: widget.saver,
            analysis: widget.analysis,
            moveMenu: _mode == Mode.study
                ? (path) => quizMenuItems(widget.session, path)
                : null,
          ),
        ),
      ],
    );
  }
}

/// The modes `v2` has. Each one fills the left column; the workspace, the
/// document and the draft in it are the same whichever is showing.
enum Mode {
  repertoires('Repertoires'),
  study('Study');

  const Mode(this.label);

  final String label;
}

/// The outline between the library and the board, with the rule that it is
/// only there when a chapter is: its rows are that chapter's repertoire and
/// its lines.
class _OutlineColumn extends StatelessWidget {
  const _OutlineColumn({
    required this.outline,
    required this.library,
    required this.session,
    required this.onOpen,
  });

  final ChapterOutline outline;
  final Library library;
  final DocumentSession session;
  final ValueChanged<ChapterRef> onOpen;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: outlineColumnWidth,
        child: OutlinePanel(
          outline: outline,
          library: library,
          session: session,
          onOpen: onOpen,
        ),
      ),
      const VerticalDivider(width: 1),
    ],
  );
}

/// Modes not yet in v2 are listed but disabled, so the menu shows the whole
/// product from day one and each step turns one entry on.
const _modes = [
  'Repertoires',
  'PGN Viewer',
  'Repertoire builder',
  'Repertoire trainer',
  'Study',
  'Tactics',
  'Player analysis',
  'Players & prep',
  'Databases',
  'Engine tournament',
  'Bughouse lab',
];

class _TopBar extends StatelessWidget {
  const _TopBar({required this.mode, required this.onMode});

  final Mode mode;
  final ValueChanged<Mode> onMode;

  /// The mode this entry switches to, or null when `v2` does not have it yet
  /// and the entry is there only to show that the product does.
  Mode? _modeNamed(String name) =>
      Mode.values.where((mode) => mode.label == name).firstOrNull;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.m,
        vertical: Space.xs,
      ),
      child: Row(
        children: [
          MenuAnchor(
            menuChildren: [
              for (final name in _modes)
                MenuItemButton(
                  onPressed: switch (_modeNamed(name)) {
                    null => null,
                    final named => () => onMode(named),
                  },
                  leadingIcon: name == mode.label
                      ? const Icon(Icons.check, size: IconSize.menu)
                      : const SizedBox(width: IconSize.menu),
                  child: Text(name),
                ),
            ],
            builder: (context, controller, _) => TextButton.icon(
              onPressed: controller.isOpen ? controller.close : controller.open,
              icon: const Icon(Icons.menu, size: IconSize.action),
              label: Text(mode.label),
            ),
          ),
          const Spacer(),
          Text(
            'Chess Auto Prep',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ],
      ),
    );
  }
}

class _ErrorBar extends StatelessWidget {
  const _ErrorBar(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(
        horizontal: Space.l,
        vertical: Space.s,
      ),
      child: Text(text, style: TextStyle(color: scheme.onErrorContainer)),
    );
  }
}
