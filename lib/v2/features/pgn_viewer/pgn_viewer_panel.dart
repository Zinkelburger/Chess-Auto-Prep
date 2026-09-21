import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../chess/pgn/game_summary.dart';
import '../../storage/chapter_files.dart';
import '../../ui/row_actions.dart';
import '../../ui/search_field.dart';
import '../../ui/theme.dart';
import 'pgn_viewer.dart';

/// Opens a PGN file in the workspace with its first game on the board.
typedef OpenPgnFile = void Function(ChapterRef file);

/// The PGN Viewer's column: the file that is open and its games, or the
/// files opened before when none is.
///
/// Opening and closing a file are the host's, because they take the
/// workspace off the document it has; everything else here is a command
/// over the viewer or the session. The panel itself keeps only what the
/// user typed into the search field.
class PgnViewerPanel extends StatefulWidget {
  const PgnViewerPanel({
    super.key,
    required this.viewer,
    required this.onOpen,
    required this.onClose,
  });

  final PgnViewer viewer;
  final OpenPgnFile onOpen;
  final VoidCallback onClose;

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

  Future<void> _browse() async {
    final path = await _viewer.browse();
    if (path == null || !mounted) return;
    widget.onOpen(ChapterRef.at(path));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _viewer,
      builder: (context, _) {
        final file = _viewer.file;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Toolbar(
              hasFile: file != null,
              onBrowse: _browse,
              onClose: widget.onClose,
            ),
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
      return _Empty(onBrowse: _browse);
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
            onOpen: () => widget.onOpen(ChapterRef.at(path)),
          ),
      ],
    );
  }

  Widget _games(BuildContext context, ChapterRef file) {
    final rows = _viewer.visible;
    final current = _viewer.current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FileAndCounter(
          name: file.name,
          current: current,
          total: _viewer.games.length,
          onPrevious: _viewer.previousGame,
          onNext: _viewer.nextGame,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.m, 0, Space.s, Space.s),
          child: SearchField(
            controller: _search,
            hint: 'Search games',
            onChanged: _viewer.search,
          ),
        ),
        if (rows.isEmpty)
          _Message(
            _viewer.games.isEmpty
                ? 'No games in this file.'
                : 'Nothing matches "${_viewer.query}".',
          )
        else
          Expanded(
            child: ListView.builder(
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
            ),
          ),
      ],
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.hasFile,
    required this.onBrowse,
    required this.onClose,
  });

  final bool hasFile;
  final VoidCallback onBrowse;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.s, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'PGN Viewer',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          RowActions(
            tooltip: 'Viewer actions',
            children: [
              rowAction('Open PGN file…', onBrowse, busy: false),
              rowAction('Close file', onClose, busy: !hasFile),
            ],
          ),
        ],
      ),
    );
  }
}

/// The open file's name over `‹ Game n of N ›`.
class _FileAndCounter extends StatelessWidget {
  const _FileAndCounter({
    required this.name,
    required this.current,
    required this.total,
    required this.onPrevious,
    required this.onNext,
  });

  final String name;
  final int? current;
  final int total;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final at = current;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, Space.xs, Space.s, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: text.titleMedium, overflow: TextOverflow.ellipsis),
          Row(
            children: [
              IconButton(
                onPressed: at != null && at > 0 ? onPrevious : null,
                icon: const Icon(Icons.chevron_left, size: IconSize.action),
                tooltip: 'Previous game',
                visualDensity: VisualDensity.compact,
              ),
              Text(
                at == null ? '$total games' : 'Game ${at + 1} of $total',
                style: text.bodySmall,
              ),
              IconButton(
                onPressed: at != null && at + 1 < total ? onNext : null,
                icon: const Icon(Icons.chevron_right, size: IconSize.action),
                tooltip: 'Next game',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
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
/// files called `games.pgn` can be told apart.
class _RecentRow extends StatelessWidget {
  const _RecentRow({required this.path, required this.onOpen});

  final String path;
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
              p.dirname(path),
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
