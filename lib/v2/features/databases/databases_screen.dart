import 'dart:async';

import 'package:flutter/material.dart';

import '../../storage/master_corpus.dart';
import '../../ui/number_field.dart';
import '../../ui/theme.dart';
import 'database_library.dart';
import 'twic_download_dialog.dart';

class DatabasesScreen extends StatelessWidget {
  const DatabasesScreen({
    super.key,
    required this.library,
    required this.onOpen,
  });
  final DatabaseLibrary library;
  final ValueChanged<CorpusGame> onOpen;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: library,
    builder: (context, _) => Padding(
      padding: const EdgeInsets.all(Space.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(context),
          const SizedBox(height: Space.m),
          Wrap(
            spacing: Space.s,
            children: [
              for (final name in library.sources.keys)
                ChoiceChip(
                  label: Text(name),
                  selected: name == library.source,
                  onSelected: library.activity == DatabaseActivity.importing
                      ? null
                      : (_) => library.select(name),
                ),
            ],
          ),
          const SizedBox(height: Space.m),
          _CorpusFilters(key: ValueKey(library.source), library: library),
          const SizedBox(height: Space.m),
          if (library.activity != DatabaseActivity.idle)
            const LinearProgressIndicator(),
          _status(context),
          const Divider(),
          Expanded(child: _games(context)),
          _pages(),
        ],
      ),
    ),
  );

  Widget _heading(BuildContext context) => Wrap(
    alignment: WrapAlignment.spaceBetween,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: Space.l,
    children: [
      Text('Databases', style: Theme.of(context).textTheme.titleLarge),
      Wrap(
        spacing: Space.s,
        children: [
          if (library.download != null)
            FilledButton.icon(
              icon: const Icon(Icons.download),
              onPressed: () => unawaited(_download(context)),
              label: const Text('Download TWIC…'),
            ),
          OutlinedButton.icon(
            icon: const Icon(Icons.file_open),
            onPressed:
                library.activity == DatabaseActivity.idle &&
                    library.download != null
                ? () => unawaited(library.importFile())
                : null,
            label: const Text('Import PGN…'),
          ),
          IconButton(
            tooltip: 'Refresh database counts',
            onPressed: () => unawaited(library.refresh()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    ],
  );

  Future<void> _download(BuildContext context) async {
    final download = library.download;
    if (download == null) return;
    await showTwicDownload(context, download);
    await library.refresh();
  }

  Widget _status(BuildContext context) {
    final problem = library.problem;
    final message = switch (library.activity) {
      DatabaseActivity.importing => 'Importing games…',
      DatabaseActivity.reading => 'Reading games…',
      DatabaseActivity.idle =>
        '${library.size.games} games · '
            '${(library.size.bytes / 1048576).toStringAsFixed(1)} MB',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.s),
      child: Text(
        problem ?? library.message ?? message,
        style: problem == null
            ? null
            : TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    );
  }

  Widget _games(BuildContext context) {
    final games = library.page.games;
    if (games.isEmpty) {
      return Center(
        child: Text(
          library.size.games == 0
              ? 'Download TWIC or import a PGN to browse games.'
              : 'No games match these filters.',
        ),
      );
    }
    return ListView.builder(
      itemCount: games.length,
      itemBuilder: (context, index) {
        final game = games[index];
        final ratings =
            '${game.whiteElo == 0 ? '—' : game.whiteElo} / '
            '${game.blackElo == 0 ? '—' : game.blackElo}';
        return ListTile(
          key: ValueKey('corpus-game-${game.id}'),
          title: Text(
            '${game.white} — ${game.black}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${game.date} · ${game.event} · ${game.eco} · $ratings',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(library.opening == game.id ? 'Opening…' : game.result),
          onTap:
              library.opening != null ||
                  library.activity != DatabaseActivity.idle
              ? null
              : () => onOpen(game),
        );
      },
    );
  }

  Widget _pages() => Row(
    children: [
      Text('Page ${library.filter.offset ~/ 100 + 1}'),
      const Spacer(),
      TextButton(
        onPressed:
            library.filter.offset == 0 ||
                library.activity != DatabaseActivity.idle
            ? null
            : () => _page(-100),
        child: const Text('Previous'),
      ),
      TextButton(
        onPressed:
            !library.page.more || library.activity != DatabaseActivity.idle
            ? null
            : () => _page(100),
        child: const Text('Next'),
      ),
    ],
  );

  void _page(int by) {
    final f = library.filter;
    unawaited(
      library.search(
        CorpusFilter(
          player: f.player,
          event: f.event,
          eco: f.eco,
          minimumElo: f.minimumElo,
          since: f.since,
          strongestFirst: f.strongestFirst,
          offset: f.offset + by,
        ),
      ),
    );
  }
}

class _CorpusFilters extends StatefulWidget {
  const _CorpusFilters({super.key, required this.library});
  final DatabaseLibrary library;

  @override
  State<_CorpusFilters> createState() => _CorpusFiltersState();
}

class _CorpusFiltersState extends State<_CorpusFilters> {
  late final _player = TextEditingController(
    text: widget.library.filter.player,
  );
  late final _event = TextEditingController(text: widget.library.filter.event);
  late final _eco = TextEditingController(text: widget.library.filter.eco);
  late final _since = TextEditingController(text: widget.library.filter.since);
  int _elo = 0;
  bool _strongest = false;

  @override
  void initState() {
    super.initState();
    _elo = widget.library.filter.minimumElo;
    _strongest = widget.library.filter.strongestFirst;
  }

  Timer? _timer;

  void _changed([String? _]) {
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      unawaited(
        widget.library.search(
          CorpusFilter(
            player: _player.text,
            event: _event.text,
            eco: _eco.text,
            since: _since.text,
            minimumElo: _elo,
            strongestFirst: _strongest,
          ),
        ),
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final controller in [_player, _event, _eco, _since])
      controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: Space.m,
    runSpacing: Space.s,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      _field(_player, 'Player', 220),
      _field(_event, 'Event', 200),
      _field(_eco, 'ECO', 90),
      _field(_since, 'From date', 170),
      const Text('Min Elo'),
      SizedBox(
        width: 160,
        child: NumberField(
          label: 'Minimum Elo',
          value: _elo,
          min: 0,
          max: 3500,
          onChanged: (value) {
            if (!mounted) return;
            setState(() => _elo = value);
            _changed();
          },
        ),
      ),
      FilterChip(
        label: const Text('Strongest first'),
        selected: _strongest,
        onSelected: (value) {
          if (!mounted) return;
          setState(() => _strongest = value);
          _changed();
        },
      ),
      TextButton(
        onPressed: () {
          for (final c in [_player, _event, _eco, _since]) c.clear();
          if (!mounted) return;
          setState(() {
            _elo = 0;
            _strongest = false;
          });
          _changed();
        },
        child: const Text('Clear filters'),
      ),
    ],
  );

  Widget _field(TextEditingController controller, String label, double width) =>
      SizedBox(
        width: width,
        child: TextField(
          key: ValueKey(label),
          controller: controller,
          decoration: InputDecoration(
            labelText: label,
            hintText: controller == _since ? 'YYYY.MM.DD' : null,
            prefixIcon: const Icon(Icons.search),
          ),
          onChanged: _changed,
        ),
      );
}
