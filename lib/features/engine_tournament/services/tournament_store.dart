/// Where tournaments live: one directory per tournament under
/// `Documents/engine_tournaments/`, holding `tournament.json` (config plus
/// the result of every game) and `games.pgn` (the games themselves).
///
/// The split is deliberate. The PGN is a plain, portable collection any tool
/// can open — including this app's own PGN Viewer, which is how you look at
/// the games — and the JSON carries only what PGN has no place for.
///
/// Pure `dart:io` so the headless runner uses the same store the app does.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../services/storage/file_mutation_service.dart';
import '../../../utils/atomic_file.dart';
import '../models/stored_tournament.dart';
import '../models/tournament_config.dart';
import '../models/tournament_game.dart';

const String kEngineTournamentsDirectoryName = 'engine_tournaments';
const String _kMetadataFile = 'tournament.json';
const String _kPgnFile = 'games.pgn';

class TournamentStore {
  TournamentStore(this.root);

  /// `Documents/engine_tournaments`.
  final Directory root;

  Future<void> ensureRoot() async {
    if (!await root.exists()) await root.create(recursive: true);
  }

  String directoryFor(String id) => p.join(root.path, id);
  String pgnPathFor(String id) => p.join(root.path, id, _kPgnFile);
  String metadataPathFor(String id) => p.join(root.path, id, _kMetadataFile);

  /// Newest first.
  Future<List<StoredTournament>> list() async {
    if (!await root.exists()) return const [];
    final out = <StoredTournament>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      if (p.basename(entity.path).startsWith('.')) continue;
      final loaded = await load(p.basename(entity.path));
      if (loaded != null) out.add(loaded);
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  Future<StoredTournament?> load(String id) async {
    final file = File(metadataPathFor(id));
    if (!await file.exists()) return null;
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return null;
      return StoredTournament.fromJson(
        Map<String, dynamic>.from(json),
        directoryPath: directoryFor(id),
        pgnPath: pgnPathFor(id),
      );
    } catch (_) {
      // A half-written or hand-edited file should hide one tournament, not
      // break the list.
      return null;
    }
  }

  /// Reserve a directory for a new tournament named [name].
  Future<StoredTournament> create(TournamentConfig config) async {
    await ensureRoot();
    final id = await _allocateId(config.name);
    final dir = Directory(directoryFor(id));
    await dir.create(recursive: true);
    final tournament = StoredTournament(
      id: id,
      directoryPath: dir.path,
      pgnPath: pgnPathFor(id),
      config: config,
      createdAt: DateTime.now(),
      status: TournamentStatus.pending,
    );
    await save(tournament);
    await writeTextFileAtomically(
      File(tournament.pgnPath),
      '',
      createOnly: true,
    );
    return tournament;
  }

  Future<void> save(StoredTournament tournament) async {
    final file = File(metadataPathFor(tournament.id));
    await file.parent.create(recursive: true);
    await writeTextFileAtomically(
      file,
      const JsonEncoder.withIndent('  ').convert(tournament.toJson()),
    );
  }

  /// Replace `games.pgn` with [games], in order.
  ///
  /// Rewritten rather than appended: with several games in flight they finish
  /// out of order, and the file has to stay in schedule order for a game's
  /// number in the table to be its number in the viewer.
  Future<void> writeGamesPgn(String id, List<String> games) async {
    final file = File(pgnPathFor(id));
    await file.parent.create(recursive: true);
    await writeTextFileAtomically(file, games.join('\n'));
  }

  Future<void> delete(String id) async {
    final dir = Directory(directoryFor(id));
    await FileMutationService.instance.quarantineDirectory(
      dir,
      allowedRoot: root,
      quarantineRoot: Directory(p.join(root.path, '.trash')),
    );
  }

  Future<void> rename(String id, String newName) async {
    final tournament = await load(id);
    if (tournament == null) return;
    await save(
      tournament.copyWith(config: tournament.config.copyWith(name: newName)),
    );
  }

  Future<String> _allocateId(String name) async {
    final base = _slugify(name);
    var candidate = base;
    var suffix = 2;
    while (await Directory(directoryFor(candidate)).exists()) {
      candidate = '$base-$suffix';
      suffix++;
    }
    return candidate;
  }
}

String _slugify(String name) {
  final slug = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return slug.isEmpty ? 'tournament' : slug;
}

/// Records for the games written to `games.pgn`, numbered by their position
/// in that file.
List<TournamentGameRecord> renumber(List<TournamentGameRecord> games) => [
  for (var i = 0; i < games.length; i++)
    TournamentGameRecord(
      gameIndex: i,
      round: games[i].round,
      whiteIndex: games[i].whiteIndex,
      blackIndex: games[i].blackIndex,
      whiteName: games[i].whiteName,
      blackName: games[i].blackName,
      result: games[i].result,
      termination: games[i].termination,
      detail: games[i].detail,
      plies: games[i].plies,
      startedAt: games[i].startedAt,
      durationMs: games[i].durationMs,
    ),
];
