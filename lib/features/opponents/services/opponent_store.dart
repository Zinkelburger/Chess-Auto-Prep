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
/// per change. The MCP tooling (`people_populate`, `people_upsert`) writes
/// the same files while the app is closed; rows keep its `lookup` report in
/// [PersonRecord.extra].
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../models/analysis_player_info.dart';
import '../../../services/storage/app_paths.dart';
import '../../../services/storage/storage_factory.dart';
import '../../../utils/atomic_file.dart';
import '../../../utils/safe_change_notifier.dart';
import '../models/person_record.dart';
import '../models/tournament.dart';

/// The format tag written into `people.json`.
const kPeopleFormat = 'chess-auto-prep/people@1';

const _peopleFileName = 'people.json';
const _tournamentsDirectoryName = 'tournaments';
const _jsonExtension = '.json';

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
      File(p.join((await _root()).path, _peopleFileName));

  Future<Directory> _tournamentsDir() async {
    final dir = Directory(
      p.join((await _root()).path, _tournamentsDirectoryName),
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<String> _tournamentPath(String id) async =>
      p.join((await _tournamentsDir()).path, '$id$_jsonExtension');

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
      if (entity is! File ||
          p.extension(entity.path).toLowerCase() != _jsonExtension) {
        continue;
      }
      out[p.basenameWithoutExtension(entity.path)] = await entity
          .readAsString();
    }
    return out;
  }

  @override
  Future<void> writeTournament(String id, String json) async =>
      _writer.writeText(File(await _tournamentPath(id)), json);

  @override
  Future<void> deleteTournament(String id) async =>
      _deleter(await _tournamentPath(id));
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

/// In-memory directory and tournaments, written through to [OpponentStorage].
///
/// Reads are synchronous once [ensureLoaded] completes. Writes are serialized
/// in call order so a quick succession of edits lands on disk in the order
/// they were made, and each write snapshots the state at the moment it was
/// requested.
class OpponentStore extends ChangeNotifier with SafeChangeNotifier {
  OpponentStore(this._storage);

  static OpponentStore? _instance;

  /// The app-wide store over the documents directory.
  static OpponentStore get instance =>
      _instance ??= OpponentStore(FileOpponentStorage());

  static const _encoder = JsonEncoder.withIndent('  ');

  final OpponentStorage _storage;
  final Map<String, PersonRecord> _people = {};
  final Map<String, Tournament> _tournaments = {};
  Future<void>? _loading;
  bool _loaded = false;
  bool _savedAccountsImported = false;

  /// The tail of the write chain; every write waits for the one before it.
  Future<void>? _pendingWrites;

  bool get isLoaded => _loaded;

  /// Whether the one-time import of the app's saved accounts has run, so
  /// deleting a record is not undone on next opening.
  bool get savedAccountsImported => _savedAccountsImported;

  Future<String?> get location => _storage.location;

  /// Loads once. After that it returns a fresh completed future rather than
  /// the original one, so a caller in another zone (a widget test's fake
  /// async) is not left awaiting a future that zone never drives.
  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    _loadPeople(await _storage.readPeople());
    _loadTournaments(await _storage.readTournaments());
    if (isDisposed) return;
    _loaded = true;
    notifyListeners();
  }

  /// Accepts both the enveloped form this app writes and a bare list of
  /// people. An unreadable file starts the directory empty rather than
  /// blocking the whole feature.
  void _loadPeople(String? raw) {
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      _savedAccountsImported =
          decoded is Map && decoded['saved_accounts_imported'] == true;
      final rows = decoded is Map ? decoded['people'] : decoded;
      for (final row in (rows as List?) ?? const []) {
        if (row is Map) {
          final person = PersonRecord.fromJson(row.cast<String, dynamic>());
          _people[person.id] = person;
        }
      }
    } catch (e) {
      debugPrint('$_peopleFileName unreadable, starting empty: $e');
    }
  }

  void _loadTournaments(Map<String, String> files) {
    for (final MapEntry(key: id, value: json) in files.entries) {
      try {
        _tournaments[id] = Tournament.fromJson(
          (jsonDecode(json) as Map).cast<String, dynamic>(),
          fallbackId: id,
        );
      } catch (e) {
        debugPrint('tournament $id unreadable, skipped: $e');
      }
    }
  }

  /// Queues [write] behind every earlier write. A failed write rejects its
  /// own future but does not block the ones queued after it.
  ///
  /// The chain is dropped once it drains so the next write starts
  /// synchronously in its caller's zone: a future created in another zone
  /// (a widget test's real-async `setUp`) is never driven by a fake-async
  /// test body, and chaining onto it would hang the test.
  Future<void> _persist(Future<void> Function() write) {
    final result = switch (_pendingWrites) {
      null => write(),
      final pending => pending.then((_) => write()),
    };
    late final Future<void> tail;
    void drained() {
      if (identical(_pendingWrites, tail)) _pendingWrites = null;
    }

    tail = result.then<void>(
      (_) => drained(),
      onError: (Object _, StackTrace _) => drained(),
    );
    _pendingWrites = tail;
    return result;
  }

  // ── People ──────────────────────────────────────────────────────

  /// Everyone, by name.
  List<PersonRecord> get people =>
      _people.values.toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  PersonRecord? person(String id) => _people[id];

  /// Name, alias, handle or USCF ID contains every word of [query].
  List<PersonRecord> searchPeople(String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+'))
      ..removeWhere((w) => w.isEmpty);
    if (words.isEmpty) return people;
    return people.where((person) {
      final haystack = [
        person.name,
        ...person.aliases,
        person.uscfId ?? '',
        person.chesscom ?? '',
        person.lichess ?? '',
      ].join(' ').toLowerCase();
      return words.every(haystack.contains);
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
    final id = _normalizedKey(uscfId);
    final chesscomHandles = _handleSet(chesscom);
    final lichessHandles = _handleSet(lichess);
    final personName = _normalizedKey(name);
    final candidates = _people.values;
    if (id != null) {
      for (final person in candidates) {
        if (_normalizedKey(person.uscfId) == id) return person;
      }
    }
    for (final person in candidates) {
      if (_hasHandle(person, 'chesscom', chesscomHandles) ||
          _hasHandle(person, 'lichess', lichessHandles)) {
        return person;
      }
    }
    if (personName != null) {
      for (final person in candidates) {
        // A namesake on record under a different USCF ID is someone else.
        if ((_normalizedKey(person.name) == personName ||
                person.aliases.any((a) => _normalizedKey(a) == personName)) &&
            (id == null || person.uscfId == null)) {
          return person;
        }
      }
    }
    return null;
  }

  static String? _normalizedKey(String? value) {
    final key = value?.trim().toLowerCase();
    return (key == null || key.isEmpty) ? null : key;
  }

  /// The lower-cased handles in a user-entered account cell, or empty.
  static Set<String> _handleSet(String? cell) => {
    if (_normalizedKey(cell) != null)
      for (final handle in accountNames(cell)) handle.toLowerCase(),
  };

  static bool _hasHandle(
    PersonRecord person,
    String platform,
    Set<String> handles,
  ) =>
      handles.isNotEmpty &&
      person.accounts.any(
        (a) =>
            a.platform == platform &&
            handles.contains(a.username.toLowerCase()),
      );

  /// The person whose game-set is stored under [playerName] (see
  /// [PersonRecord.playerName]).
  PersonRecord? personForPlayerName(String playerName) {
    final key = playerName.trim().toLowerCase();
    for (final person in _people.values) {
      if (person.playerName.toLowerCase() == key) return person;
    }
    return null;
  }

  /// The directory person whose games [player] holds: an explicit link
  /// first, then an imported game-set stored under their name, then any
  /// shared online handle.
  PersonRecord? personForPlayer(AnalysisPlayerInfo player) {
    for (final person in people) {
      if (person.gameSetKeys.contains(player.playerKey)) return person;
    }
    if (player.isImported) {
      final byName = personForPlayerName(player.username);
      if (byName != null) return byName;
    }
    return matchPerson(
      chesscom: _handlesOf(player, 'chesscom'),
      lichess: _handlesOf(player, 'lichess'),
    );
  }

  /// The player's handles on [platform] as one account cell.
  static String _handlesOf(AnalysisPlayerInfo player, String platform) =>
      player.platform == platform
      ? player.username
      : player.accounts
            .where((a) => a.platform == platform)
            .map((a) => a.username)
            .join(', ');

  /// How many tournaments list this person.
  int tournamentCountFor(String personId) =>
      _tournaments.values.where((t) => t.contains(personId)).length;

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
    _savedAccountsImported = true;
    try {
      await _writePeople();
    } catch (_) {
      _savedAccountsImported = false;
      rethrow;
    }
  }

  Future<void> _writePeople() {
    final json = _encoder.convert({
      'format': kPeopleFormat,
      'saved_accounts_imported': _savedAccountsImported,
      'people': [for (final person in people) person.toJson()],
    });
    return _persist(() => _storage.writePeople(json));
  }

  // ── Tournaments ────────────────────────────────────────────────

  /// Newest first: by date when both have one, else by last change.
  List<Tournament> get tournaments =>
      _tournaments.values.toList()..sort(_newestFirst);

  static int _newestFirst(Tournament a, Tournament b) {
    if (a.date case final aDate?) {
      if (b.date case final bDate? when aDate != bDate) {
        return bDate.compareTo(aDate);
      }
    }
    return b.updatedAt.compareTo(a.updatedAt);
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
    final now = DateTime.now();
    final trimmedDate = date?.trim();
    return saveTournament(
      Tournament(
        id: _unusedTournamentId(name),
        name: name.trim(),
        date: (trimmedDate == null || trimmedDate.isEmpty) ? null : trimmedDate,
        rounds: rounds,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  /// The slug for [name], suffixed `-2`, `-3`, … while a tournament already
  /// owns it.
  String _unusedTournamentId(String name) {
    final base = newTournamentId(name);
    var id = base;
    for (var suffix = 2; _tournaments.containsKey(id); suffix++) {
      id = '$base-$suffix';
    }
    return id;
  }

  Future<Tournament> saveTournament(Tournament tournament) async {
    final stored = tournament.copyWith(updatedAt: DateTime.now());
    _tournaments[stored.id] = stored;
    final json = _encoder.convert(stored.toJson());
    await _persist(() => _storage.writeTournament(stored.id, json));
    notifyListeners();
    return stored;
  }

  Future<void> deleteTournament(String id) async {
    if (_tournaments.remove(id) == null) return;
    await _persist(() => _storage.deleteTournament(id));
    notifyListeners();
  }
}
