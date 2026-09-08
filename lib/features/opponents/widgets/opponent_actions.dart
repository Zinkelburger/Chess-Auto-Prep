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
import '../../../services/pgn_parsing_service.dart';
import '../../../services/game_identity.dart';
import '../../../services/storage/storage_factory.dart';
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

  List<AnalysisPlayerInfo> gameSetsFor(
    Iterable<AnalysisPlayerInfo> sets,
    PersonRecord person,
  ) => sets.where((set) {
    if (person.gameSetKeys.contains(set.playerKey) ||
        (set.platform == 'import' &&
            set.username.toLowerCase() == person.playerName.toLowerCase())) {
      return true;
    }
    final accounts = set.accounts.isNotEmpty
        ? set.accounts
        : [
            if (set.platform != 'import')
              PlayerAccount(set.platform, set.username),
          ];
    // Reuse only corpora whose accounts all belong to this person.
    return accounts.isNotEmpty &&
        accounts.every(
          (a) => person.accounts.any(
            (b) =>
                a.platform == b.platform &&
                a.username.toLowerCase() == b.username.toLowerCase(),
          ),
        );
  }).toList();

  AnalysisPlayerInfo? gameSetFor(
    Map<String, AnalysisPlayerInfo> sets,
    PersonRecord person,
  ) {
    final matches = gameSetsFor(sets.values, person);
    return matches.isEmpty ? null : matches.first;
  }

  Future<int> addSavedPlayers() async {
    await store.ensureLoaded();
    var added = 0;
    for (final set in await games.getAllCachedPlayers()) {
      final accounts = set.accounts.isNotEmpty
          ? set.accounts
          : [
              if (set.platform != 'import')
                PlayerAccount(set.platform, set.username),
            ];
      var person = store.personForPlayer(set);
      if (person == null) {
        person = PersonRecord.create(
          name: set.displayName,
          chesscom: accounts
              .where((a) => a.platform == 'chesscom')
              .map((a) => a.username)
              .join(', '),
          lichess: accounts
              .where((a) => a.platform == 'lichess')
              .map((a) => a.username)
              .join(', '),
        );
        added++;
      }
      await store.savePerson(
        person.copyWith(
          gameSetKeys: {...person.gameSetKeys, set.playerKey}.toList(),
        ),
      );
    }
    return added;
  }

  /// Reuse downloaded accounts and explicitly linked PGNs before downloading.
  Future<AnalysisPlayerInfo?> ensureGames(
    BuildContext context,
    PersonRecord person, {
    String? group,
  }) async {
    final saved = gameSetsFor(await games.getAllCachedPlayers(), person);
    if (saved.isNotEmpty) {
      await store.savePerson(
        (store.person(person.id) ?? person).copyWith(
          gameSetKeys: {
            ...person.gameSetKeys,
            for (final s in saved) s.playerKey,
          }.toList(),
        ),
      );
      if (saved.length == 1) return saved.single.copyWith(group: group);
      final chunks = <String, String>{};
      for (final set in saved) {
        final pgn = await games.loadAnalysisGames(set.platform, set.username);
        if (pgn != null) {
          for (final game in splitPgnIntoGames(pgn)) {
            chunks[canonicalGameKey(extractHeaders(game), game)] = game.trim();
          }
        }
      }
      if (chunks.isNotEmpty) {
        final info = await games.saveAnalysisGames(
          chunks.values.join('\n\n'),
          platform: 'import',
          username: person.playerName,
          maxGames: 100,
          accounts: person.accounts,
          group: group,
        );
        await store.savePerson(
          (store.person(person.id) ?? person).copyWith(
            gameSetKeys: {
              ...person.gameSetKeys,
              info.playerKey,
              for (final s in saved) s.playerKey,
            }.toList(),
          ),
        );
        return info;
      }
    }
    if (!context.mounted) return null;
    if (!person.hasAccount) {
      showAppSnackBar(context, 'Add an account in the row to download games.');
      return null;
    }
    final wanted = person.toPlayerInfo(
      group: group,
      monthsBack: defaultMonthsBack,
    );
    final ok = await downloads.downloadOne(context, wanted);
    if (!ok) return null;
    final info = await games.findExistingPlayer(
      wanted.platform,
      wanted.username,
    );
    if (info != null) {
      await store.savePerson(
        (store.person(person.id) ?? person).copyWith(
          gameSetKeys: {...person.gameSetKeys, info.playerKey}.toList(),
        ),
      );
    }
    return info;
  }

  Future<void> openStudyLink(BuildContext context, PlayerStudyLink link) async {
    if (!await StorageFactory.instance.fileExists(link.path)) {
      if (context.mounted) {
        showAppSnackBar(
          context,
          'This file has moved or is missing: ${link.path}',
          isError: true,
        );
      }
      return;
    }
    if (!context.mounted) return;
    final app = context.read<AppState>();
    popToRoot(context);
    app.handOff(EditStudy(studyPath: link.path, chapterName: link.chapter));
  }

  Future<void> openGroupStudy(BuildContext context, Tournament group) async {
    final path = await prepFiles.ensureGroup(group);
    if (context.mounted) {
      await openStudyLink(context, PlayerStudyLink(path: path));
    }
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
    final path = await prepFiles.ensureGroup(tournament);
    if (!context.mounted) return;
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
