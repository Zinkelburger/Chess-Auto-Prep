/// The opponents directory and the tournaments on disk.
///
/// Two kinds of file under `Documents/opponents/`:
///
/// ```
/// people.json                 every person you have ever entered
/// tournaments/<id>.json       one field per tournament, referencing people
/// ```
///
/// Both are small (a field is dozens of rows, the directory hundreds), so the
/// store keeps everything in memory after one load and rewrites a whole file
/// per change. The MCP tooling never reads these; its hand-off stays the
/// opponents.json file, which [TournamentImport] turns into a tournament.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../services/storage/app_paths.dart';
import '../../../models/analysis_player_info.dart';
import '../../../services/storage/storage_factory.dart';
import '../../../utils/atomic_file.dart';
import '../../../utils/safe_change_notifier.dart';
import '../models/person_record.dart';
import '../models/tournament.dart';

const kPeopleFormat = 'chess-auto-prep/people@1';

/// Where the store reads and writes. The file backend is the real one; the
/// memory backend lets widget tests run without `dart:io`.
abstract class OpponentStorage {
  Future<String?> readPeople();
  Future<void> writePeople(String json);

  /// Every tournament file, keyed by its id (the file stem).
  Future<Map<String, String>> readTournaments();
  Future<void> writeTournament(String id, String json);
  Future<void> deleteTournament(String id);

  /// Where the files live, for the user; null when there is no directory.
  Future<String?> get location;
}

class FileOpponentStorage implements OpponentStorage {
  FileOpponentStorage({
    Future<Directory> Function()? root,
    AtomicFileWriter? writer,
    Future<void> Function(String path)? deleter,
  }) : _root = root ?? (() => AppPaths.opponentsDirectory(create: true)),
       _writer = writer ?? AtomicFileWriter(),
       // The storage service quarantines a document rather than deleting
       // it, so a deleted tournament can still be fished out of the trash.
       _deleter =
           deleter ?? ((path) => StorageFactory.instance.deleteFile(path));

  final Future<Directory> Function() _root;
  final AtomicFileWriter _writer;
  final Future<void> Function(String path) _deleter;

  Future<File> _peopleFile() async =>
      File(p.join((await _root()).path, 'people.json'));

  Future<Directory> _tournamentsDir() async {
    final dir = Directory(p.join((await _root()).path, 'tournaments'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  @override
  Future<String?> get location async => (await _root()).path;

  @override
  Future<String?> readPeople() async {
    final file = await _peopleFile();
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<void> writePeople(String json) async =>
      _writer.writeText(await _peopleFile(), json);

  @override
  Future<Map<String, String>> readTournaments() async {
    final dir = await _tournamentsDir();
    final out = <String, String>{};
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.json')) {
        continue;
      }
      out[p.basenameWithoutExtension(entity.path)] = await entity
          .readAsString();
    }
    return out;
  }

  @override
  Future<void> writeTournament(String id, String json) async =>
      _writer.writeText(
        File(p.join((await _tournamentsDir()).path, '$id.json')),
        json,
      );

  @override
  Future<void> deleteTournament(String id) async =>
      _deleter(p.join((await _tournamentsDir()).path, '$id.json'));
}

class MemoryOpponentStorage implements OpponentStorage {
  String? people;
  final Map<String, String> tournaments = {};

  @override
  Future<String?> get location async => null;

  @override
  Future<String?> readPeople() async => people;

  @override
  Future<void> writePeople(String json) async => people = json;

  @override
  Future<Map<String, String>> readTournaments() async => Map.of(tournaments);

  @override
  Future<void> writeTournament(String id, String json) async =>
      tournaments[id] = json;

  @override
  Future<void> deleteTournament(String id) async => tournaments.remove(id);
}

class OpponentStore extends ChangeNotifier with SafeChangeNotifier {
  OpponentStore(this._storage);

  static OpponentStore? _instance;

  /// The app-wide store over the documents directory.
  static OpponentStore get instance =>
      _instance ??= OpponentStore(FileOpponentStorage());

  final OpponentStorage _storage;
  final Map<String, PersonRecord> _people = {};
  final Map<String, Tournament> _tournaments = {};
  Future<void>? _loading;
  bool _loaded = false;
  bool savedAccountsImported = false;
  Future<void>? _writes;

  Future<void> _persist(Future<void> Function() write) {
    final result = _writes == null ? write() : _writes!.then((_) => write());
    late final Future<void> tail;
    void finished() {
      if (identical(_writes, tail)) _writes = null;
    }

    tail = result.then<void>(
      (_) => finished(),
      onError: (Object _, StackTrace _) => finished(),
    );
    _writes = tail;
    return result;
  }

  bool get isLoaded => _loaded;

  Future<String?> get location => _storage.location;

  /// Loads once. After that it returns a fresh completed future rather than
  /// the original one, so a caller in another zone (a widget test's fake
  /// async) is not left awaiting a future that zone never drives.
  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    final raw = await _storage.readPeople();
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        savedAccountsImported =
            decoded is Map && decoded['saved_accounts_imported'] == true;
        final rows = decoded is Map ? decoded['people'] : decoded;
        for (final row in (rows as List?) ?? const []) {
          if (row is Map) {
            final person = PersonRecord.fromJson(row.cast<String, dynamic>());
            _people[person.id] = person;
          }
        }
      } catch (e) {
        debugPrint('people.json unreadable, starting empty: $e');
      }
    }
    for (final entry in (await _storage.readTournaments()).entries) {
      try {
        final t = Tournament.fromJson(
          (jsonDecode(entry.value) as Map).cast<String, dynamic>(),
          fallbackId: entry.key,
        );
        _tournaments[entry.key] = t;
      } catch (e) {
        debugPrint('tournament ${entry.key} unreadable, skipped: $e');
      }
    }
    if (isDisposed) return;
    _loaded = true;
    notifyListeners();
  }

  // ── People ──────────────────────────────────────────────────────

  /// Everyone, by name.
  List<PersonRecord> get people {
    final out = _people.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  PersonRecord? person(String id) => _people[id];

  /// Name, handle or USCF ID contains every word of [query].
  List<PersonRecord> searchPeople(String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+'))
      ..removeWhere((w) => w.isEmpty);
    if (words.isEmpty) return people;
    return people.where((person) {
      final hay = [
        person.name,
        person.uscfId ?? '',
        person.chesscom ?? '',
        person.lichess ?? '',
      ].join(' ').toLowerCase();
      return words.every(hay.contains);
    }).toList();
  }

  /// The person these facts already describe, strongest key first: a USCF
  /// ID, then an online handle, then the exact name. Null when nobody
  /// matches — the caller creates a new record.
  PersonRecord? matchPerson({
    String? uscfId,
    String? chesscom,
    String? lichess,
    String? name,
  }) {
    String? norm(String? s) {
      final t = s?.trim().toLowerCase();
      return (t == null || t.isEmpty) ? null : t;
    }

    final id = norm(uscfId);
    final cc = norm(chesscom);
    final li = norm(lichess);
    final nm = norm(name);
    for (final person in _people.values) {
      if (id != null && norm(person.uscfId) == id) return person;
    }
    for (final person in _people.values) {
      if (cc != null &&
          person.accounts.any(
            (a) =>
                a.platform == 'chesscom' &&
                accountNames(
                  cc,
                ).any((n) => n.toLowerCase() == a.username.toLowerCase()),
          )) {
        return person;
      }
      if (li != null &&
          person.accounts.any(
            (a) =>
                a.platform == 'lichess' &&
                accountNames(
                  li,
                ).any((n) => n.toLowerCase() == a.username.toLowerCase()),
          )) {
        return person;
      }
    }
    for (final person in _people.values) {
      if (nm != null &&
          norm(person.name) == nm &&
          (id == null || person.uscfId == null || norm(person.uscfId) == id)) {
        return person;
      }
    }
    return null;
  }

  /// The person whose game-set is stored under [playerName] (see
  /// [PersonRecord.playerName]).
  PersonRecord? personForPlayerName(String playerName) {
    final key = playerName.trim().toLowerCase();
    for (final person in _people.values) {
      if (person.playerName.toLowerCase() == key) return person;
    }
    return null;
  }

  PersonRecord? personForPlayer(AnalysisPlayerInfo player) {
    for (final person in people) {
      if (person.gameSetKeys.contains(player.playerKey)) return person;
    }
    return (player.platform == 'import'
            ? personForPlayerName(player.username)
            : null) ??
        matchPerson(
          chesscom: player.platform == 'chesscom'
              ? player.username
              : player.accounts
                    .where((a) => a.platform == 'chesscom')
                    .map((a) => a.username)
                    .join(', '),
          lichess: player.platform == 'lichess'
              ? player.username
              : player.accounts
                    .where((a) => a.platform == 'lichess')
                    .map((a) => a.username)
                    .join(', '),
        );
  }

  /// How many tournaments list this person.
  int tournamentCountFor(String personId) =>
      _tournaments.values.where((t) => t.contains(personId)).length;

  /// Tournaments listing this person, newest first.
  List<Tournament> tournamentsFor(String personId) =>
      tournaments.where((t) => t.contains(personId)).toList();

  /// Insert or replace. Returns the stored record (with a fresh
  /// `updatedAt`).
  Future<PersonRecord> savePerson(PersonRecord person) async {
    final stored = person.copyWith(updatedAt: DateTime.now());
    _people[stored.id] = stored;
    await _writePeople();
    notifyListeners();
    return stored;
  }

  /// Remove the person and every tournament entry that points at them.
  Future<void> deletePerson(String id) async {
    if (_people.remove(id) == null) return;
    await _writePeople();
    for (final t in _tournaments.values.toList()) {
      if (t.contains(id)) await saveTournament(t.withoutPerson(id));
    }
    notifyListeners();
  }

  /// Remember onboarding so deleting a record is not undone on next opening.
  Future<void> markSavedAccountsImported() async {
    savedAccountsImported = true;
    try {
      await _writePeople();
    } catch (_) {
      savedAccountsImported = false;
      rethrow;
    }
  }

  Future<void> _writePeople() {
    final json = const JsonEncoder.withIndent('  ').convert({
      'format': kPeopleFormat,
      'saved_accounts_imported': savedAccountsImported,
      'people': [for (final p in people) p.toJson()],
    });
    return _persist(() => _storage.writePeople(json));
  }

  // ── Tournaments ────────────────────────────────────────────────

  /// Newest first: by date when both have one, else by last change.
  List<Tournament> get tournaments {
    final out = _tournaments.values.toList()
      ..sort((a, b) {
        if (a.date != null && b.date != null && a.date != b.date) {
          return b.date!.compareTo(a.date!);
        }
        return b.updatedAt.compareTo(a.updatedAt);
      });
    return out;
  }

  Tournament? tournament(String id) => _tournaments[id];

  Tournament? tournamentNamed(String name) {
    final key = name.trim().toLowerCase();
    for (final t in _tournaments.values) {
      if (t.name.toLowerCase() == key) return t;
    }
    return null;
  }

  Future<Tournament> createTournament(
    String name, {
    String? date,
    int? rounds,
  }) async {
    var id = newTournamentId(name);
    var suffix = 2;
    while (_tournaments.containsKey(id)) {
      id = '${newTournamentId(name)}-${suffix++}';
    }
    final now = DateTime.now();
    final t = Tournament(
      id: id,
      name: name.trim(),
      date: (date?.trim().isEmpty ?? true) ? null : date!.trim(),
      rounds: rounds,
      createdAt: now,
      updatedAt: now,
    );
    return saveTournament(t);
  }

  Future<Tournament> saveTournament(Tournament tournament) async {
    final stored = tournament.copyWith(updatedAt: DateTime.now());
    _tournaments[stored.id] = stored;
    await _persist(
      () => _storage.writeTournament(
        stored.id,
        const JsonEncoder.withIndent('  ').convert(stored.toJson()),
      ),
    );
    notifyListeners();
    return stored;
  }

  Future<void> deleteTournament(String id) async {
    if (_tournaments.remove(id) == null) return;
    await _persist(() => _storage.deleteTournament(id));
    notifyListeners();
  }
}
