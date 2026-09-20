import 'package:flutter/material.dart';

import '../features/library/library.dart';
import '../features/library/library_panel.dart';
import '../storage/chapter_files.dart';
import '../ui/theme.dart';
import '../workspace/document_session.dart';
import '../workspace/workspace_view.dart';

/// The window: a top bar with the mode menu, the library on the left and the
/// workspace filling the rest. Opening a chapter from the library into the
/// workspace is the one cross-feature request, and it is handled here.
class Shell extends StatefulWidget {
  const Shell({super.key, required this.library, required this.session});

  final Library library;
  final DocumentSession session;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _opens = 0;
  String? _error;

  /// Opens [ref] unless a later click has overtaken this one, so two quick
  /// clicks always end on the second chapter, however long each read takes.
  Future<void> _open(ChapterRef ref) async {
    final ticket = ++_opens;
    final result = await widget.library.open(ref);
    if (!mounted || ticket != _opens) return;
    switch (result) {
      case Opened(:final chapter):
        widget.session.open(chapter, source: ref);
        setState(() => _error = null);
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
                  width: 260,
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
                Expanded(child: WorkspaceView(session: widget.session)),
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
                      ? const Icon(Icons.check, size: 16)
                      : const SizedBox(width: 16),
                  child: Text(name),
                ),
            ],
            builder: (context, controller, _) => TextButton.icon(
              onPressed: controller.isOpen ? controller.close : controller.open,
              icon: const Icon(Icons.menu, size: 18),
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
