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
  ChapterRef? _selected;
  String? _error;

  Future<void> _open(ChapterRef ref) async {
    final result = await widget.library.open(ref);
    if (!mounted) return;
    switch (result) {
      case Opened(:final chapter):
        widget.session.open(chapter);
        setState(() {
          _selected = ref;
          _error = null;
        });
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
                  child: LibraryPanel(
                    library: widget.library,
                    selected: _selected,
                    onOpen: _open,
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
/// product from day one and each step turns one entry on.
const _modes = [
  ('Repertoires', true),
  ('PGN Viewer', false),
  ('Repertoire builder', false),
  ('Repertoire trainer', false),
  ('Study', false),
  ('Tactics', false),
  ('Player analysis', false),
  ('Players & prep', false),
  ('Databases', false),
  ('Engine tournament', false),
  ('Bughouse lab', false),
];

class _TopBar extends StatelessWidget {
  const _TopBar();

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
              for (final (name, available) in _modes)
                MenuItemButton(
                  onPressed: available ? () {} : null,
                  child: Text(name),
                ),
            ],
            builder: (context, controller, _) => TextButton.icon(
              onPressed: controller.isOpen ? controller.close : controller.open,
              icon: const Icon(Icons.menu, size: 18),
              label: const Text('Repertoires'),
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
