import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../models/analysis_player_info.dart';
import '../../../theme/app_text_styles.dart';
import '../models/person_record.dart';
import '../models/tournament.dart';
import '../services/opponent_store.dart';
import 'opponent_actions.dart';
import 'player_cell.dart';
import 'player_study_links.dart';

/// The same editable rows in the directory and every group.
class PlayerTable extends StatefulWidget {
  const PlayerTable({
    super.key,
    required this.store,
    required this.actions,
    required this.people,
    required this.onAnalyse,
    required this.onRemove,
    this.group,
    this.newPersonId,
    this.onOpenGames,
  });
  final OpponentStore store;
  final OpponentActions actions;
  final List<PersonRecord> people;
  final Tournament? group;
  final String? newPersonId;
  final Future<void> Function(AnalysisPlayerInfo)? onOpenGames;
  final Future<void> Function(PersonRecord) onAnalyse;
  final Future<void> Function(PersonRecord) onRemove;

  @override
  State<PlayerTable> createState() => _PlayerTableState();
}

class _PlayerTableState extends State<PlayerTable> {
  final _horizontal = ScrollController();
  List<AnalysisPlayerInfo> _sets = [];
  String? _error;
  String? _linksFor;
  String? _accountsFor;
  String? _busy;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    try {
      final sets = await widget.actions.games.getAllCachedPlayers();
      if (mounted) setState(() => _sets = sets);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not read saved games: $e');
    }
  }

  Future<void> _run(String id, Future<void> Function() action) async {
    if (!mounted || _busy != null) return;
    setState(() {
      _busy = id;
      _error = null;
    });
    try {
      await action();
      await _reload();
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not complete this action: $e');
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _edit(
    String id,
    PersonRecord Function(PersonRecord) update,
  ) async {
    final current = widget.store.person(id);
    if (current == null) return;
    // Remember the currently associated corpus before a name/account edit.
    final keys = {
      ...current.gameSetKeys,
      for (final set in widget.actions.gameSetsFor(_sets, current))
        set.playerKey,
    };
    await widget.store.savePerson(
      update(current).copyWith(gameSetKeys: keys.toList()),
    );
  }

  @override
  void dispose() {
    _horizontal.dispose();
    super.dispose();
  }

  static const _widths = [
    52.0,
    180.0,
    118.0,
    150.0,
    150.0,
    210.0,
    160.0,
    82.0,
    180.0,
    44.0,
  ];
  Widget _cell(int index, Widget child) => index == 0 && widget.group == null
      ? const SizedBox.shrink()
      : SizedBox(
          width: _widths[index],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: child,
          ),
        );

  @override
  Widget build(BuildContext context) {
    final width =
        _widths.reduce((a, b) => a + b) -
        (widget.group == null ? _widths.first : 0);
    return Column(
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => Scrollbar(
              controller: _horizontal,
              thumbVisibility: true,
              scrollbarOrientation: ScrollbarOrientation.bottom,
              child: SingleChildScrollView(
                controller: _horizontal,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: math.max(width, constraints.maxWidth),
                  child: Column(
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                        ),
                        child: Row(
                          children: [
                            for (final (index, label) in [
                              'Ready',
                              'Name',
                              'USCF ID',
                              'Chess.com accounts',
                              'Lichess accounts',
                              'Reference studies',
                              'Games',
                              'Rating',
                              'Notes',
                              '',
                            ].indexed)
                              _cell(
                                index,
                                Text(label, style: AppTextStyles.caption),
                              ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: widget.people.isEmpty
                            ? const Center(
                                child: Text(
                                  'Add your first player, or paste a list from a spreadsheet.',
                                ),
                              )
                            : ListView(
                                children: [
                                  for (final person in widget.people)
                                    _row(person),
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(PersonRecord person) {
    final group = widget.group;
    final entry = group == null || group.indexOf(person.id) < 0
        ? null
        : group.entries[group.indexOf(person.id)];
    final sets = widget.actions.gameSetsFor(_sets, person);
    final links = [
      if (person.prepFilePath != null)
        PlayerStudyLink(path: person.prepFilePath!),
      ...person.studyLinks,
    ];
    Widget field(
      String name,
      String value,
      PersonRecord Function(PersonRecord, String) update, {
      String? Function(String)? validate,
    }) => PlayerCell(
      key: Key('player-${person.id}-$name'),
      value: value,
      label: name,
      autofocus: person.id == widget.newPersonId && name == 'Name',
      validate: validate,
      save: (value) => _edit(person.id, (p) => update(p, value)),
    );
    String? handles(String value) =>
        accountNames(value).any((n) => !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(n))
        ? 'Use usernames, separated by commas.'
        : null;
    return Container(
      key: Key('opponent-row-${person.id}'),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _cell(
                0,
                entry == null
                    ? const SizedBox()
                    : Checkbox(
                        key: Key('opponent-prepared-${person.id}'),
                        value: entry.prepared,
                        onChanged: (value) => _run(person.id, () async {
                          final current = widget.store.tournament(group!.id)!;
                          final latest =
                              current.entries[current.indexOf(person.id)];
                          await widget.store.saveTournament(
                            current.withEntry(latest.copyWith(prepared: value)),
                          );
                        }),
                      ),
              ),
              _cell(
                1,
                field(
                  'Name',
                  person.name,
                  (p, v) => p.copyWith(name: v),
                  validate: (v) =>
                      v.isEmpty ? 'Enter a name or username.' : null,
                ),
              ),
              _cell(
                2,
                field(
                  'USCF ID',
                  person.uscfId ?? '',
                  (p, v) => p.copyWith(uscfId: v, clearUscfId: v.isEmpty),
                  validate: (v) => v.isNotEmpty && !RegExp(r'^\d+$').hasMatch(v)
                      ? 'Digits only.'
                      : null,
                ),
              ),
              _cell(
                3,
                field(
                  'Chess.com',
                  person.chesscom ?? '',
                  (p, v) => p.copyWith(chesscom: v, clearChesscom: v.isEmpty),
                  validate: handles,
                ),
              ),
              _cell(
                4,
                field(
                  'Lichess',
                  person.lichess ?? '',
                  (p, v) => p.copyWith(lichess: v, clearLichess: v.isEmpty),
                  validate: handles,
                ),
              ),
              _cell(
                5,
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final link in links)
                      Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              style: TextButton.styleFrom(
                                alignment: Alignment.centerLeft,
                              ),
                              onPressed: () => _run(
                                person.id,
                                () =>
                                    widget.actions.openStudyLink(context, link),
                              ),
                              child: Text(
                                link.chapter == null
                                    ? p.basenameWithoutExtension(link.path)
                                    : '${p.basenameWithoutExtension(link.path)} · ${link.chapter}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          if (person.studyLinks.contains(link))
                            IconButton(
                              tooltip:
                                  'Unlink ${link.chapter ?? p.basename(link.path)}',
                              icon: const Icon(Icons.link_off, size: 16),
                              onPressed: () => _run(
                                person.id,
                                () => _edit(
                                  person.id,
                                  (p) => p.copyWith(
                                    studyLinks: p.studyLinks
                                        .where((l) => l != link)
                                        .toList(),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    Wrap(
                      children: [
                        if (person.prepFilePath == null)
                          TextButton(
                            onPressed: () => _run(person.id, () async {
                              await widget.actions.prepFiles.ensure(
                                widget.store.person(person.id)!,
                              );
                            }),
                            child: const Text('New study'),
                          ),
                        OutlinedButton(
                          key: Key('player-link-${person.id}'),
                          onPressed: () {
                            if (mounted) {
                              setState(
                                () => _linksFor = _linksFor == person.id
                                    ? null
                                    : person.id,
                              );
                            }
                          },
                          child: Text(
                            _linksFor == person.id
                                ? 'Close links'
                                : 'Link study',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              _cell(
                6,
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sets.isEmpty
                          ? (person.hasAccount
                                ? 'No saved games'
                                : 'No account linked')
                          : sets.length == 1
                          ? '${sets.single.gameCount} saved'
                          : '${sets.length} saved sources',
                      style: AppTextStyles.caption,
                    ),
                    FilledButton(
                      key: Key('prepare-${person.id}'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      onPressed:
                          _busy != null || (!person.hasAccount && sets.isEmpty)
                          ? null
                          : () => _run(
                              person.id,
                              () => widget.onAnalyse(
                                widget.store.person(person.id)!,
                              ),
                            ),
                      child: Text(
                        _busy == person.id
                            ? 'Working…'
                            : widget.group == null
                            ? 'Analyze games'
                            : 'Prepare',
                      ),
                    ),
                    if (sets.isNotEmpty)
                      TextButton(
                        onPressed: () {
                          if (mounted) {
                            setState(
                              () => _accountsFor = _accountsFor == person.id
                                  ? null
                                  : person.id,
                            );
                          }
                        },
                        child: const Text('Saved sources'),
                      ),
                  ],
                ),
              ),
              _cell(
                7,
                field(
                  'Rating',
                  person.rating?.toString() ?? '',
                  (p, v) => p.copyWith(
                    rating: int.tryParse(v),
                    clearRating: v.isEmpty,
                  ),
                  validate: (v) =>
                      v.isNotEmpty &&
                          (int.tryParse(v) == null || int.parse(v) < 0)
                      ? 'Use a number.'
                      : null,
                ),
              ),
              _cell(
                8,
                field('Notes', person.notes, (p, v) => p.copyWith(notes: v)),
              ),
              _cell(
                9,
                IconButton(
                  tooltip: group == null
                      ? 'Delete player'
                      : 'Remove from group',
                  onPressed: () =>
                      _run(person.id, () => widget.onRemove(person)),
                  icon: const Icon(Icons.remove_circle_outline, size: 18),
                ),
              ),
            ],
          ),
          if (_linksFor == person.id)
            SizedBox(
              width: MediaQuery.sizeOf(context).width,
              child: PlayerStudyLinks(
                key: ValueKey('links-${person.id}'),
                personId: person.id,
                store: widget.store,
              ),
            ),
          if (_accountsFor == person.id)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 12,
                children: [
                  for (final set in sets)
                    OutlinedButton(
                      onPressed: () {
                        if (!mounted) return;
                        final info = set.copyWith(group: group?.name);
                        if (widget.onOpenGames != null) {
                          unawaited(
                            _run(person.id, () => widget.onOpenGames!(info)),
                          );
                        } else {
                          Navigator.of(context).pop(info);
                        }
                      },
                      child: Text(
                        '${set.platformDisplayName}: ${set.displayName} · ${set.gameCount} games',
                      ),
                    ),
                  if (person.hasAccount)
                    TextButton(
                      onPressed: () => _run(person.id, () async {
                        await widget.actions.downloads.downloadOne(
                          context,
                          person.toPlayerInfo(
                            group: group?.name,
                            monthsBack: 6,
                          ),
                        );
                      }),
                      child: const Text('Download latest games'),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
