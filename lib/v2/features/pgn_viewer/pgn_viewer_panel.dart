import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../chess/pgn/game_summary.dart';
import '../../storage/chapter_files.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import 'pgn_viewer.dart';

/// Opens a PGN file in the workspace with its first game on the board.
typedef OpenPgnFile = void Function(ChapterRef file);

/// The PGN Viewer's column: the file that is open and its games, or the
/// files opened before when none is. A `+` beside the name at the top opens
/// another; the corner after it is the host's, for the pane's own toggle.
///
/// Opening a file is the host's, because it takes the workspace off the
/// document it has; closing one is in the Actions menu with everything
/// else that can be done to the document. The panel itself keeps only what
/// the user typed into the search field.
class PgnViewerPanel extends StatefulWidget {
  const PgnViewerPanel({
    super.key,
    required this.viewer,
    required this.onOpen,
    required this.onBrowse,
    this.trailing,
  });

  final PgnViewer viewer;

  /// A file from the recent list.
  final OpenPgnFile onOpen;

  /// The desktop's file dialog, which the host runs so its key and its menu
  /// entry go through the same door.
  final VoidCallback onBrowse;

  /// What sits in the top right corner: the host's toggle for the pane.
  final Widget? trailing;

  @override
  State<PgnViewerPanel> createState() => _PgnViewerPanelState();
}

class _PgnViewerPanelState extends State<PgnViewerPanel> {
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(widget.viewer.loadRecent());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  PgnViewer get _viewer => widget.viewer;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _viewer,
      builder: (context, _) {
        final file = _viewer.file;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Toolbar(onBrowse: widget.onBrowse, trailing: widget.trailing),
            if (_viewer.recentProblem case final problem?) _Message(problem),
            Expanded(
              child: file == null ? _recent(context) : _games(context, file),
            ),
          ],
        );
      },
    );
  }

  Widget _recent(BuildContext context) {
    final recent = _viewer.recent;
    if (recent.isEmpty) {
      return _Empty(onBrowse: widget.onBrowse);
    }
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.m, 0),
          child: Text(
            'Recent files',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        ),
        for (final path in recent)
          _RecentRow(
            path: path,
            folderShown: _viewer.folderShown(path),
            onOpen: () => widget.onOpen(ChapterRef.at(path)),
          ),
      ],
    );
  }

  Widget _games(BuildContext context, ChapterRef file) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.m, Space.xs, Space.s, 0),
          child: Text(
            file.name,
            style: Theme.of(context).textTheme.titleMedium,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.m,
            Space.s,
            Space.s,
            Space.s,
          ),
          child: SearchField(
            controller: _search,
            hint: 'Search games',
            onChanged: _viewer.search,
          ),
        ),
        Expanded(child: _rows()),
      ],
    );
  }

  /// The games that match the search, only the rows on screen built.
  Widget _rows() {
    final rows = _viewer.visible;
    final current = _viewer.current;
    if (rows.isEmpty) {
      return _Message(
        _viewer.games.isEmpty
            ? 'No games in this file.'
            : 'Nothing matches "${_viewer.query}".',
      );
    }
    return ListView.builder(
      itemCount: rows.length,
      itemExtent: listRowHeight,
      itemBuilder: (context, at) {
        final (index, game) = rows[at];
        return _GameRow(
          index: index,
          game: game,
          open: index == current,
          onOpen: () => _viewer.showGame(index),
        );
      },
    );
  }
}

/// The panel's name with the one thing to do before a file is open beside
/// it, and the host's toggle in the corner.
class _Toolbar extends StatelessWidget {
  const _Toolbar({required this.onBrowse, required this.trailing});

  final VoidCallback onBrowse;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.s, 0),
      child: Row(
        children: [
          // Room for the buttons first: a narrow pane cuts the label.
          Flexible(
            child: Text(
              'PGN Viewer',
              style: Theme.of(context).textTheme.labelSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: Space.xs),
          IconButton(
            icon: const Icon(Icons.add, size: IconSize.action),
            tooltip: 'Open PGN file… (Ctrl+O)',
            onPressed: onBrowse,
            visualDensity: VisualDensity.compact,
          ),
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }
}

/// One game of the open file: its number, its players and how it ended.
class _GameRow extends StatelessWidget {
  const _GameRow({
    required this.index,
    required this.game,
    required this.open,
    required this.onOpen,
  });

  final int index;
  final GameSummary game;

  /// This is the game on the board.
  final bool open;

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: open ? theme.colorScheme.surfaceContainerHighest : null,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.m, 0, Space.m, 0),
          child: Row(
            children: [
              SizedBox(
                width: gameOrdinalWidth,
                child: Text('${index + 1}', style: theme.textTheme.labelSmall),
              ),
              Expanded(
                child: Text(game.title, overflow: TextOverflow.ellipsis),
              ),
              if (game.result.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: Space.s),
                  child: Text(game.result, style: theme.textTheme.labelSmall),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A file opened before: its name, and the folder it is in under it so two
/// files called `games.pgn` can be told apart. The folder is shown from the
/// user's home down, which is what they know it by.
class _RecentRow extends StatelessWidget {
  const _RecentRow({
    required this.path,
    required this.folderShown,
    required this.onOpen,
  });

  final String path;

  /// The folder as the viewer names it, from the user's home down.
  final String folderShown;

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.m,
          vertical: Space.xs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(p.basename(path), overflow: TextOverflow.ellipsis),
            Text(
              folderShown,
              style: text.labelSmall,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onBrowse});

  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Space.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'No PGN open.\nOpen a file to read its games.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: Space.s),
          FilledButton(
            onPressed: onBrowse,
            child: const Text('Open PGN file…'),
          ),
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
