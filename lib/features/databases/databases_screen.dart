import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../storage/disk_usage.dart';
import '../../storage/master_corpus.dart';
import '../../ui/confirm_dialog.dart';
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
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_summary(library.size)),
                const SizedBox(height: Space.xs),
                Text(
                  databaseAbout,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.l),
          _CorpusFilters(library: library),
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
          if (library.offersDownload)
            Tooltip(
              message:
                  'Weekly issues of The Week in Chess from theweekinchess.com',
              child: FilledButton.icon(
                icon: const Icon(Icons.download),
                onPressed: library.activity == DatabaseActivity.importing
                    ? null
                    : () => unawaited(showTwicDownload(context, library)),
                label: const Text('Download TWIC…'),
              ),
            ),
          Tooltip(
            message: 'Adds a PGN file’s games to the master games',
            child: OutlinedButton.icon(
              icon: const Icon(Icons.file_open),
              onPressed:
                  library.activity == DatabaseActivity.idle &&
                      !library.busy &&
                      library.path != null
                  ? () => unawaited(library.importFile())
                  : null,
              label: const Text('Import PGN…'),
            ),
          ),
          if (library.places != null) _StorageButton(library: library),
          IconButton(
            tooltip: 'Refresh database counts and storage',
            onPressed: () {
              unawaited(library.refresh());
              unawaited(library.measure());
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    ],
  );

  Widget _status(BuildContext context) {
    final problem = library.problem;
    final message = switch (library.activity) {
      DatabaseActivity.importing => 'Importing games…',
      DatabaseActivity.reading => 'Reading games…',
      DatabaseActivity.idle => '',
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
              ? library.offersDownload
                    ? 'Download TWIC or import a PGN to browse games.'
                    : 'Import a PGN to add your own games here.'
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
  const _CorpusFilters({required this.library});
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
            labelText: controller == _since ? '$label (YYYY.MM.DD)' : label,
            prefixIcon: const Icon(Icons.search),
          ),
          onChanged: _changed,
        ),
      );
}

/// `Master games · 1,944,320 games · 2.0 GB · Sep 2020 – Sep 2026 · TWIC
/// issues 1340–1612 · 2 PGN files imported`, or what is missing.
String _summary(CorpusSize size) {
  if (size.games == 0) return 'Master games · empty';
  return [
    'Master games',
    '${_count(size.games)} games',
    _bytes(size.bytes),
    if (_span(size) case final span?) span,
    if (size.firstIssue > 0)
      size.firstIssue == size.lastIssue
          ? 'TWIC issue ${size.firstIssue}'
          : 'TWIC issues ${size.firstIssue}–${size.lastIssue}',
    if (size.imports > 0)
      size.imports == 1
          ? '1 PGN file imported'
          : '${size.imports} PGN files imported',
  ].join(' · ');
}

String _count(int n) => NumberFormat.decimalPattern().format(n);

String _bytes(int bytes) => bytes >= 1 << 30
    ? '${(bytes / (1 << 30)).toStringAsFixed(1)} GB'
    : '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';

/// `Sep 2020 – Sep 2026` from PGN dates; null when neither is readable.
String? _span(CorpusSize size) {
  final first = _month(size.firstDate);
  final last = _month(size.lastDate);
  if (first == null && last == null) return null;
  if (first == null || last == null || first == last) return first ?? last;
  return '$first – $last';
}

String? _month(String pgnDate) {
  final parts = pgnDate.split('.');
  final year = int.tryParse(parts.first);
  if (year == null) return null;
  final month = parts.length > 1 ? int.tryParse(parts[1]) : null;
  if (month == null || month < 1 || month > 12) return '$year';
  return DateFormat.yMMM().format(DateTime(year, month));
}

/// What the app keeps on disk, measured: a button in the heading that opens
/// the list. It is for the day the disk fills up, not for every visit.
class _StorageButton extends StatelessWidget {
  const _StorageButton({required this.library});
  final DatabaseLibrary library;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    key: const ValueKey('storage'),
    icon: const Icon(Icons.storage),
    onPressed: () => unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => _StorageDialog(library: library),
      ),
    ),
    label: Text(
      library.measuring && library.storage.isEmpty
          ? 'Storage · measuring…'
          : 'Storage · ${formatBytes(_total(library.storage))}',
    ),
  );
}

int _total(List<StoreUsage> stores) =>
    stores.fold(0, (sum, store) => sum + store.bytes);

class _StorageDialog extends StatelessWidget {
  const _StorageDialog({required this.library});
  final DatabaseLibrary library;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: library,
    builder: (context, _) {
      final muted = Theme.of(context).colorScheme.onSurfaceVariant;
      return AlertDialog(
        title: Text('Storage · ${formatBytes(_total(library.storage))}'),
        content: SizedBox(
          width: 480,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final store in library.storage)
                if (store.bytes > 0)
                  ListTile(
                    key: ValueKey('store-${store.name}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Tooltip(
                      message: store.path,
                      child: Text(store.name),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          formatBytes(store.bytes),
                          style: TextStyle(color: muted),
                        ),
                        if (store.removable)
                          IconButton(
                            tooltip: 'Delete ${store.name}',
                            onPressed:
                                library.removing != null || store.bytes == 0
                                ? null
                                : () => unawaited(_remove(context, store)),
                            icon: const Icon(Icons.delete_outline),
                          ),
                      ],
                    ),
                  ),
              if (library.problem case final problem?)
                Text(
                  problem,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );

  Future<void> _remove(BuildContext context, StoreUsage store) async {
    final sure = await confirmAction(
      context,
      title: 'Delete ${store.name}?',
      message: store.name.startsWith('Leftover')
          ? 'A copy left beside a database the app rebuilds. '
                'Deleting it frees ${formatBytes(store.bytes)}.'
          : 'Frees ${formatBytes(store.bytes)}. Download TWIC and import '
                'the PGN files again to get the games back; the PGN files '
                'themselves are not touched.',
      confirm: 'Delete',
    );
    if (sure) await library.remove(store);
  }
}
