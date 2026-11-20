// The stores that keep user data outside the PGN documents, as the app
// wires them (`AppEnvironment.native`): settings.json, the PGN Viewer's
// unsaved edits, the engine tournaments and the player directory. Built on
// the standard profile with one record of each seeded, so a fault matrix
// can check that a write to one of them lands whole or not at all and that
// every other record still reads as it did.
//
// The projections below are short strings, as in stores.dart: equal exactly
// when the app would show the same thing.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/chess/tournament/config.dart';
import 'package:chess_auto_prep/chess/tournament/result.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/storage/player_files.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/storage/tournaments.dart';
import 'package:chess_auto_prep/storage/viewer_drafts.dart';
import 'package:crypto/crypto.dart';

import '../profile/profile.dart';
import '../profile/standard_profile.dart';
import 'scenario.dart';
import 'stores.dart';

final class RecordStores {
  RecordStores._(this.core, this.drafts, this.tournaments, this.players);

  /// The app's wiring on [profile]. Call it inside the run.
  static RecordStores open(Profile profile) {
    final core = Stores.open(profile);
    return RecordStores._(
      core,
      ViewerDraftFiles(Directory(profile.support)),
      FileTournaments(
        root: Directory(profile.document(tournamentsFolder)),
        support: Directory(profile.support),
        documents: core.documents,
      ),
      PlayerFiles(Directory(profile.document(playersFolder))),
    );
  }

  final Stores core;
  final ViewerDraftFiles drafts;
  final FileTournaments tournaments;
  final PlayerFiles players;

  Profile get profile => core.profile;

  /// A settings store as the app makes one at start: each call is a new
  /// one, which reads settings.json before anything changes it.
  SettingsStore settings() =>
      SettingsStore(support: Directory(profile.support));

  /// The settings a new start reads, as JSON, or why it could not.
  Future<String> settingsNow() async {
    final store = settings();
    await store.load();
    final value = store.value.toJson();
    store.dispose();
    return '${_sha(value)}${store.problem == null ? '' : ' (problem)'}';
  }

  /// The draft kept for Benko Accepted: its game and text, or none.
  Future<String> draftNow() async {
    final draft = await drafts.find(profile.document(benkoAccepted));
    return draft == null
        ? 'none'
        : 'game ${draft.game} ${draft.revision.contentHash} ${_sha(draft.text)}';
  }

  /// Each tournament the list shows, with its status, games and PGN, or
  /// why the list failed.
  Future<String> tournamentsNow() async {
    final listed = await tournaments.list();
    if (listed is! TournamentSaved<List<Tournament>>) return 'failed';
    final rows = <String>[];
    for (final t in listed.value) {
      final pgn = switch (await core.documents.open(tournaments.games(t.id))) {
        Opened(:final text) => _sha(text),
        Absent() => 'absent',
        Unreadable() => 'unreadable',
      };
      rows.add('${t.id} ${t.status} ${t.games.length} games, pgn $pgn');
    }
    return [...rows, ...listed.warnings].join('; ');
  }

  /// The players and groups the directory shows, and its warnings.
  Future<String> playersNow() async {
    final read = await players.read();
    return [
      for (final player in read.players)
        'player ${_sha(jsonEncode(player.fields))}',
      for (final group in read.groups)
        'group ${_sha(jsonEncode(group.fields))}',
      ...read.warnings,
    ].join('; ');
  }
}

/// Engine tournaments, under Documents.
const tournamentsFolder = 'engine_tournaments';

/// The player directory, under Documents.
const playersFolder = 'opponents';

/// The seeded tournament: one game played, still running.
Tournament seededTournament() => Tournament({
  'version': 1,
  'id': 'match',
  'createdAt': '2026-09-27',
  'status': 'running',
  'config': {
    'name': 'Match',
    'engines': [
      TournamentEngine.bundled().json,
      TournamentEngine.bundled().json,
    ],
  },
  'games': [
    {'whiteIndex': 0, 'blackIndex': 1, 'result': '1-0'},
  ],
});

const seededTournamentPgn =
    '[Event "Match"]\n[Round "1"]\n[Result "1-0"]\n\n1. e4 e5 2. Qh5 1-0\n';

/// The seeded players, in file order: an unknown field kept as written.
final seededPlayers = [
  Player({'id': 'p-ann', 'name': 'Ann', 'rating': 2010, 'x_future': true}),
  Player({'id': 'p-bob', 'name': 'Bob', 'rating': 1890}),
];

final seededGroup = PlayerGroup({
  'format': 'chess-auto-prep/tournament@1',
  'id': 'club',
  'name': 'Club championship',
  'entries': [
    {'person': 'p-ann'},
    {'person': 'p-bob'},
  ],
});

/// The revision the seeded draft's edits were made against.
const seededDraftRevision =
    'c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00c0ffee00';

/// The draft the seeded profile keeps for Benko Accepted.
ViewerDraft seededDraft(Profile profile) => ViewerDraft(
  path: profile.document(benkoAccepted),
  game: 0,
  revision: const Revision(seededDraftRevision),
  text: '[Event "Draft"]\n[Result "*"]\n\n1. d4 Nf6 2. c4 c5 3. d5 b5 *\n',
);

/// The standard profile with a viewer draft, an engine tournament and a
/// player directory, each written by its own store.
Future<void> seedRecordProfile(Profile profile) async {
  await seedStandardProfile(profile);
  final support = Directory(profile.support);
  await ViewerDraftFiles(support).keep(seededDraft(profile));
  final tournaments = FileTournaments(
    root: Directory(profile.document(tournamentsFolder)),
    support: support,
    documents: PgnFileStore(
      documents: Directory(profile.documents),
      support: support,
    ),
  );
  final created = await tournaments.create(seededTournament());
  final saved = await tournaments.save(
    seededTournament(),
    seededTournament(),
    seededTournamentPgn,
    expectedPgn: null,
  );
  if (created is! TournamentSaved || saved is! TournamentSaved) {
    throw StateError('could not seed the tournament');
  }
  final players = PlayerFiles(Directory(profile.document(playersFolder)));
  for (final player in seededPlayers) {
    await players.savePlayer(player);
  }
  await players.saveGroup(seededGroup);
}

/// What the other records show; a command may change only its own.
const recordProbes = [
  Probe<RecordStores>('settings', _settings),
  Probe<RecordStores>('viewer draft', _draft),
  Probe<RecordStores>('tournaments', _tournaments),
  Probe<RecordStores>('players', _players),
  Probe<RecordStores>('open Benko Accepted', _accepted),
];

Future<String> _settings(RecordStores s) => s.settingsNow();
Future<String> _draft(RecordStores s) => s.draftNow();
Future<String> _tournaments(RecordStores s) => s.tournamentsNow();
Future<String> _players(RecordStores s) => s.playersNow();
Future<String> _accepted(RecordStores s) => s.core.openedAs(benkoAccepted);

String _sha(String text) =>
    '${sha256.convert(utf8.encode(text))}'.substring(0, 16);
