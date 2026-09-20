import 'package:flutter/material.dart';

import '../features/library/library.dart';
import '../features/library/library_panel.dart';
import '../storage/chapter_files.dart';
import '../ui/theme.dart';
import '../workspace/document_saver.dart';
import '../workspace/document_session.dart';
import '../workspace/session_results.dart';
import '../workspace/engine_analysis.dart';
import '../workspace/workspace_view.dart';
import 'exit_guard.dart';

/// The window: a top bar with the mode menu, the library on the left and the
/// workspace filling the rest. Opening a chapter from the library into the
/// workspace is the one cross-feature request, and it is handled here.
class Shell extends StatefulWidget {
  const Shell({
    super.key,
    required this.library,
    required this.session,
    required this.saver,
    required this.analysis,
    required this.leaving,
  });

  final Library library;
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

  /// The session opens the file; this only says what came of it. An open
  /// a later click overtook has nothing to say, so it says nothing.
  ///
  /// Opening a document takes the saver off the one that is open, and a
  /// draft it never wrote goes with it, so the user is asked first — the
  /// same question the closing window asks. When they answered it by saving
  /// a copy, the bar above says where those words went.
  Future<void> _open(ChapterRef ref) async {
    // Clicking the chapter that is already open is not leaving it.
    if (ref == widget.session.source) return;
    if (!await widget.leaving.mayLeaveDocument()) return;
    if (!mounted) return;
    final copy = widget.leaving.lastCopy;
    widget.leaving.lastCopy = null;
    final result = await widget.session.open(ref);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const _TopBar(),
          const Divider(height: 1),
          if (_error case final error?) _ErrorBar(error),
          Expanded(
            child: Row(
              children: [
                SizedBox(
                  width: libraryPanelWidth,
                  child: ListenableBuilder(
                    listenable: widget.session,
                    builder: (context, _) => LibraryPanel(
                      library: widget.library,
                      selected: widget.session.source,
                      onOpen: _open,
                    ),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: WorkspaceView(
                    session: widget.session,
                    saver: widget.saver,
                    analysis: widget.analysis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Modes not yet in v2 are listed but disabled, so the menu shows the whole
/// product from day one and each step turns one entry on. Repertoires is the
/// only mode, so choosing it just closes the menu.
const _currentMode = 'Repertoires';
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
  const _TopBar();

  /// Already in this mode; the item closes the menu by itself.
  static void _stayHere() {}

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
                  onPressed: name == _currentMode ? _stayHere : null,
                  leadingIcon: name == _currentMode
                      ? const Icon(Icons.check, size: IconSize.menu)
                      : const SizedBox(width: IconSize.menu),
                  child: Text(name),
                ),
            ],
            builder: (context, controller, _) => TextButton.icon(
              onPressed: controller.isOpen ? controller.close : controller.open,
              icon: const Icon(Icons.menu, size: IconSize.action),
              label: const Text(_currentMode),
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
