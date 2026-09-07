/// What you can *do* with an opponent, shared by the tournament sheet, the
/// people directory and Player Analysis so each is one call: get their
/// games, open or train their prep file, train a whole field, save a
/// tournament as text.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/app_state.dart';
import '../../../models/analysis_player_info.dart';
import '../../../services/analysis_games_service.dart';
import '../../../services/opponent_list.dart';
import '../../../utils/app_messages.dart';
import '../../../utils/atomic_file.dart';
import '../../../widgets/analysis/player_downloads.dart';
import '../../../widgets/opponent_list_import_dialog.dart';
import '../models/person_record.dart';
import '../models/tournament.dart';
import '../services/opponent_store.dart';
import '../services/prep_files.dart';
import '../services/tournament_text_export.dart';
import '../services/uscf_client.dart';

/// Pop every pushed route (picker, tournaments, sheet) so a mode switch
/// lands on the main screen rather than under a stack of routes.
void popToRoot(BuildContext context) =>
    Navigator.of(context).popUntil((route) => route.isFirst);

class OpponentActions {
  OpponentActions({
    OpponentStore? store,
    AnalysisGamesService? games,
    UscfClient Function()? uscf,
  }) : store = store ?? OpponentStore.instance,
       games = games ?? AnalysisGamesService(),
       _uscf = uscf ?? UscfClient.new {
    downloads = PlayerDownloadRunner(this.games);
    prepFiles = PrepFiles(this.store);
  }

  final OpponentStore store;
  final AnalysisGamesService games;
  final UscfClient Function() _uscf;
  late final PlayerDownloadRunner downloads;
  late final PrepFiles prepFiles;

  static const defaultMonthsBack = 6;

  // ── Games ──────────────────────────────────────────────────────

  /// Every saved game-set, keyed by lower-case username, so a person's set
  /// is `sets[person.playerName.toLowerCase()]`.
  Future<Map<String, AnalysisPlayerInfo>> gameSetsByUsername() async {
    final all = await games.getAllCachedPlayers();
    return {for (final p in all) p.username.toLowerCase(): p};
  }

  AnalysisPlayerInfo? gameSetFor(
    Map<String, AnalysisPlayerInfo> sets,
    PersonRecord person,
  ) => sets[person.playerName.toLowerCase()];

  /// The person's game-set, downloading it first when there is none.
  /// Returns null when they have no online account or the download found
  /// nothing. The result carries [group] so Player Analysis can tie it back
  /// to the tournament.
  Future<AnalysisPlayerInfo?> ensureGames(
    BuildContext context,
    PersonRecord person, {
    String? group,
  }) async {
    if (!person.hasAccount) {
      showAppSnackBar(
        context,
        '${person.name} has no Chess.com or Lichess username yet — '
        'edit them to add one.',
      );
      return null;
    }
    final wanted = person.toPlayerInfo(
      group: group,
      monthsBack: defaultMonthsBack,
    );
    var existing = await games.findExistingPlayer(
      wanted.platform,
      wanted.username,
    );
    if (existing == null) {
      if (!context.mounted) return null;
      final ok = await downloads.downloadOne(context, wanted);
      if (!ok) return null;
      existing = await games.findExistingPlayer(
        wanted.platform,
        wanted.username,
      );
    }
    return existing?.copyWith(group: group ?? existing.group);
  }

  /// Download games for everyone in the field who has an account and no
  /// saved set (or everyone, with [redownload]). Returns true if anything
  /// was saved.
  Future<bool> downloadField(
    BuildContext context,
    Tournament tournament, {
    bool redownload = false,
  }) async {
    final rows = <OpponentEntry>[
      for (final e in tournament.entries)
        if (store.person(e.personId) case final person? when person.hasAccount)
          person.asOpponentEntry,
    ];
    if (rows.isEmpty) {
      showAppSnackBar(context, 'Nobody in the field has an online account.');
      return false;
    }
    return downloads.downloadList(
      context,
      OpponentImportRequest(
        list: OpponentList(event: tournament.name, opponents: rows),
        monthsBack: defaultMonthsBack,
        redownloadExisting: redownload,
      ),
    );
  }

  // ── Prep files ─────────────────────────────────────────────────

  Future<void> openPrepFile(BuildContext context, PersonRecord person) async {
    final appState = context.read<AppState>();
    final path = await prepFiles.ensure(person);
    if (!context.mounted) return;
    popToRoot(context);
    appState.switchToStudyEdit(
      path: path,
      historyLabel: PrepFiles.nameFor(person),
    );
  }

  Future<void> trainPrepFile(BuildContext context, PersonRecord person) async {
    final appState = context.read<AppState>();
    final path = await prepFiles.ensure(person);
    final chapters = await prepFiles.chaptersOf(person);
    if (!context.mounted) return;
    if (chapters.every((c) => c.movetext.trim().isEmpty)) {
      showAppSnackBar(
        context,
        'No lines in ${person.name}’s prep file yet — add some from '
        'Player Analysis first.',
      );
      return;
    }
    popToRoot(context);
    appState.switchToStudyTraining(
      path: path,
      historyLabel: 'Train: ${person.name}',
    );
  }

  Future<void> trainTournament(
    BuildContext context,
    Tournament tournament,
  ) async {
    final appState = context.read<AppState>();
    final path = await prepFiles.mergedForTournament(tournament);
    if (!context.mounted) return;
    if (path == null) {
      showAppSnackBar(context, 'No prep lines in this field yet.');
      return;
    }
    popToRoot(context);
    appState.switchToStudyTraining(
      path: path,
      historyLabel: 'Train: ${tournament.name}',
    );
  }

  // ── Export ─────────────────────────────────────────────────────

  /// The tournament as text, ready to write.
  Future<String> renderText(Tournament tournament) async {
    final sets = await gameSetsByUsername();
    final rows = <TournamentTextRow>[];
    for (final entry in tournament.entries) {
      final person = store.person(entry.personId);
      if (person == null) continue;
      rows.add(
        TournamentTextRow(
          person: person,
          entry: entry,
          chapters: await prepFiles.chaptersOf(person),
          gameCount: gameSetFor(sets, person)?.gameCount,
        ),
      );
    }
    return renderTournamentText(tournament, rows);
  }

  /// Ask where to save, write, and say where it went. Returns the path, or
  /// null when cancelled.
  Future<String?> saveAsText(
    BuildContext context,
    Tournament tournament,
  ) async {
    final text = await renderText(tournament);
    final where = await store.location;
    final uri = await FilePicker.saveFile(
      dialogTitle: 'Save ${tournament.name} as text',
      fileName: '${tournament.name}.md',
      type: FileType.custom,
      allowedExtensions: ['md', 'txt'],
      initialDirectory: where,
      bytes: utf8.encode(text),
    );
    if (uri == null) return null;
    final path = uri.toFilePath();
    // The picker may already have written the bytes; writing again through
    // the atomic writer guarantees the file is whole either way.
    await AtomicFileWriter().writeText(File(path), text);
    if (context.mounted) showAppSnackBar(context, 'Saved $path');
    return path;
  }

  // ── US Chess ───────────────────────────────────────────────────

  /// Look up everyone in the field who has a US Chess ID and fill in the
  /// rating (and a missing name) from the ratings server. Returns how many
  /// people changed.
  Future<int> fillFromUscf(BuildContext context, Tournament tournament) async {
    final targets = <PersonRecord>[
      for (final e in tournament.entries)
        if (store.person(e.personId) case final p? when p.uscfId != null) p,
    ];
    if (targets.isEmpty) {
      showAppSnackBar(context, 'Nobody in the field has a US Chess ID.');
      return 0;
    }
    final progress = ValueNotifier<String>('Starting…');
    var cancelled = false;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Text('Asking US Chess'),
            content: ValueListenableBuilder<String>(
              valueListenable: progress,
              builder: (_, message, _) => Text(message),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  cancelled = true;
                  progress.value = 'Stopping…';
                },
                child: const Text('Stop'),
              ),
            ],
          ),
        ),
      ),
    );
    final client = _uscf();
    var changed = 0;
    final failed = <String>[];
    try {
      for (var i = 0; i < targets.length; i++) {
        if (cancelled) break;
        final person = targets[i];
        progress.value = '${person.name} (${i + 1} of ${targets.length})';
        try {
          final m = await client.member(person.uscfId!);
          final next = person.copyWith(
            rating: m.rating,
            name: person.name.trim().isEmpty ? m.name : null,
          );
          if (next.rating != person.rating || next.name != person.name) {
            await store.savePerson(next);
            changed++;
          }
        } on UscfException catch (e) {
          failed.add('${person.name}: ${e.message}');
        }
      }
    } finally {
      client.close();
      progress.dispose();
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    if (context.mounted) {
      showAppSnackBar(
        context,
        [
          'Updated $changed',
          if (failed.isNotEmpty) '${failed.length} not found',
          if (cancelled) 'stopped early',
        ].join(' · '),
        isError: failed.isNotEmpty,
      );
    }
    return changed;
  }
}
