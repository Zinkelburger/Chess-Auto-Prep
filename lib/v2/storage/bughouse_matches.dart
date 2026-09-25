import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:document_file_io/document_file_io.dart';

import 'directory_entries.dart';
import '../chess/bughouse/match.dart';
import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'file_lock.dart';
import 'recovery_files.dart';

sealed class MatchCreate {
  const MatchCreate();
}

final class MatchCreated extends MatchCreate {
  const MatchCreated(this.match);

  final StoredMatch match;
}

final class MatchCreateFailed extends MatchCreate {
  const MatchCreateFailed(this.detail);

  final String detail;
}

/// A write that did not happen, and why; null when it did.
typedef MatchWriteProblem = String?;

/// The bughouse matches on disk: one folder per match under
/// `Documents/bughouse_matches/`, holding `match.json` (the config and every
/// game) and `games.bpgn` (the games as BPGN, which `tools/bughouse_db`
/// indexes like the FICS archive). The old app reads and writes the same
/// folders; a deleted match goes to `.trash` beside them, as there.
abstract interface class MatchStore {
  /// Every match, newest first. Existing unreadable metadata makes the listing
  /// unavailable; it is never represented as a successful empty history.
  Future<List<StoredMatch>> list();

  /// A new folder named after [config], and its first `match.json`.
  Future<MatchCreate> create(MatchConfig config, DateTime now);

  /// Writes both files over the last ones.
  Future<MatchWriteProblem> save(
    StoredMatch match, {
    MatchCheckpoint? checkpoint,
  });

  /// Moves the match's folder to `.trash`.
  Future<MatchWriteProblem> delete(String id);
}

/// One accepted whole-match write, retained across an uncertain acknowledgment.
/// It binds the exact payload and destination before either file is published.
final class MatchCheckpoint {
  String? _path;
  String? _after;
  String? _before;
  String? _directory;
  bool _admitted = false;
  bool _complete = false;
}

final class MatchFolder implements MatchStore {
  MatchFolder(
    String root, {
    this.publish = replaceFile,
    this.synchronize = syncDirectory,
  }) : _configuredRoot = Directory(p.normalize(p.absolute(root))),
       root = canonicalRecoveryRoot(Directory(root)).path;

  final Directory _configuredRoot;

  void _checkRoot() {
    if (canonicalRecoveryRoot(_configuredRoot).path != root) {
      throw const FileSystemException(
        'The configured matches directory changed.',
      );
    }
  }

  /// Native publication boundary, also used to exercise lost acknowledgments.
  final Future<void> Function(String, List<int>) publish;

  /// Flushes newly created match/profile ancestry on supported native hosts.
  final Future<void> Function(String) synchronize;

  /// `Documents/bughouse_matches`.
  final String root;

  // Only immutable move strings proven by replay are reused. Keep the cache
  // bounded across histories; changed starts/moves must be replayed again.
  final _validated = <String, _ValidatedMoves>{};

  Future<_DecodedCheckpoint> _decode(String folder, String text) async {
    final previous = _validated[folder];
    final decoded = await _decodeOffThread(text, previous);
    _validated.remove(folder);
    _validated[folder] = decoded.validated;
    if (_validated.length > 8) _validated.remove(_validated.keys.first);
    return decoded;
  }

  static const _metadata = 'match.json';
  static const _bpgn = 'games.bpgn';

  @override
  Future<List<StoredMatch>> list() async {
    _checkRoot();
    final folder = Directory(root);
    final observed = await observeDirectory(root);
    if (observed.status == 1) return const [];
    if (observed.status != 0) {
      throw FileSystemException(
        'Matches directory is unreadable or unsupported',
        root,
      );
    }
    final found = <StoredMatch>[];
    await for (final entry in directoryEntries(folder, followLinks: false)) {
      if (entry is! Directory || p.basename(entry.path).startsWith('.')) {
        continue;
      }
      if (await _read(entry.path) case final match?) found.add(match);
    }
    found.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return found;
  }

  Future<StoredMatch?> _read(
    String folder,
  ) => withDirectoryLock(Directory(folder), () async {
    _checkRoot();
    late final _DecodedCheckpoint decoded;
    StoredMatch match;
    try {
      final text = await _text(p.join(folder, _metadata));
      if (text == null) return null;
      decoded = await _decode(folder, text);
      match = decoded.match;
    } on Object catch (error) {
      // Invalid/newer metadata cannot authorize repair or an empty history.
      final detail = error is FileSystemException
          ? error.message
          : 'Unsupported or invalid match checkpoint.';
      log.w('read $folder/$_metadata', detail);
      throw FileSystemException(detail, p.join(folder, _metadata));
    }
    // JSON is the existing authoritative checkpoint. BPGN is only its
    // deterministic export. A failed repair must be visible, not hide a match.
    final observed = await observeDirectory(folder);
    if (observed.status != 0) {
      throw FileSystemException('Match directory is unreadable', folder);
    }
    await discardLeftoverStage(p.join(folder, _metadata));
    await _export(folder, decoded.bpgn);
    return StoredMatch(
      id: p.basename(folder),
      config: match.config,
      createdAt: match.createdAt,
      finishedAt: match.finishedAt,
      status: match.status,
      error: match.error,
      games: match.games,
    );
  });

  Future<void> _export(String folder, String expected) async {
    final path = p.join(folder, _bpgn);
    final current = await _text(path);
    await discardLeftoverStage(path);
    if (current != expected) await publish(path, utf8.encode(expected));
  }

  @override
  Future<MatchCreate> create(MatchConfig config, DateTime now) async {
    try {
      _checkRoot();
      final directory = Directory(root);
      final boundary = recoveryMetadataBoundary(directory);
      await directory.create(recursive: true);
      return await withDirectoryLock(directory, () async {
        _checkRoot();
        await recoveryDirectory(directory);
        final id = await _freeName(config.name);
        final folder = Directory(p.join(root, id));
        await folder.create();
        final match = StoredMatch(
          id: id,
          config: config,
          createdAt: now,
          status: MatchStatus.pending,
        );
        final encoded = _encoded(match);
        await _decode(folder.path, encoded);
        await createFileExclusively(
          p.join(folder.path, _metadata),
          utf8.encode(encoded),
        );
        // The JSON's own file flush does not persist new parent directories.
        await flushRecoveryAncestry(
          folder.path,
          through: boundary,
          synchronize: synchronize,
        );
        return MatchCreated(match);
      });
    } on Object catch (error) {
      log.e('create a bughouse match in $root', error);
      return MatchCreateFailed('$error');
    }
  }

  @override
  Future<MatchWriteProblem> save(
    StoredMatch match, {
    MatchCheckpoint? checkpoint,
  }) async {
    final token = checkpoint ?? MatchCheckpoint();
    try {
      _checkRoot();
      final folder = _folder(match.id);
      final path = p.join(folder, _metadata);
      final after = await _encodeOffThread(match);
      final decoded = await _decode(folder, after);
      if (token._path != null &&
          (token._path != path || token._after != after)) {
        throw const FormatException('The accepted match checkpoint changed.');
      }
      token._path = path;
      token._after = after;
      if (token._complete) return null;
      await withDirectoryLock(Directory(folder), () async {
        _checkRoot();
        final directory = await observeDirectory(folder);
        if (directory.status != 0 ||
            (token._directory != null &&
                token._directory != directory.identity)) {
          throw const FormatException(
            'The match directory changed or is unreadable.',
          );
        }
        token._directory = directory.identity;
        final current = await _text(path);
        if (!token._admitted) {
          if (current == null) {
            throw const FormatException('The match checkpoint is missing.');
          }
          await _decode(folder, current);
          token._before = current;
          token._admitted = true;
        }
        if (current != token._before && current != after) {
          throw const FormatException(
            'The match changed in another instance. Reopen it before editing.',
          );
        }
        // Validate both participants and staging paths before the first write.
        await _text(p.join(folder, _bpgn));
        for (final file in [path, p.join(folder, _bpgn)]) {
          await discardLeftoverStage(file);
        }
        await publish(path, utf8.encode(after));
        await publish(p.join(folder, _bpgn), utf8.encode(decoded.bpgn));
      });
      _validated[folder] = decoded.validated;
      token._complete = true;
      return null;
    } on Object catch (error) {
      log.e('save the bughouse match ${match.id}', error);
      return '$error';
    }
  }

  String _folder(String id) {
    if (id.isEmpty ||
        id.startsWith('.') ||
        p.basename(id) != id ||
        id.contains('\u0000')) {
      throw const FormatException('Invalid match directory name.');
    }
    return p.join(root, id);
  }

  @override
  Future<MatchWriteProblem> delete(String id) async {
    try {
      _checkRoot();
      final folder = Directory(_folder(id));
      final trash = Directory(p.join(root, '.trash'));
      await withDirectoryLock(folder, () async {
        _checkRoot();
        if ((await observeDirectory(folder.path)).status != 0) {
          throw const FileSystemException(
            'The match directory is missing or unreadable.',
          );
        }
        await recoveryDirectory(trash, create: true);
        final stamp = DateTime.now().microsecondsSinceEpoch;
        await folder.rename(p.join(trash.path, '$id-$stamp'));
        await flushRecoveryDirectory(trash.path);
        await flushRecoveryDirectory(root);
      });
      return null;
    } on Object catch (error) {
      log.e('delete the bughouse match $id', error);
      return '$error';
    }
  }

  /// [name] as a folder name, with `-2`, `-3`… when it is taken.
  Future<String> _freeName(String name) async {
    final slug = name
        .toLowerCase()
        .replaceAll(RegExp('[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final base = slug.isEmpty ? 'match' : slug;
    var candidate = base;
    for (
      var n = 2;
      await FileSystemEntity.type(
            p.join(root, candidate),
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound;
      n++
    ) {
      candidate = '$base-$n';
    }
    return candidate;
  }

  static String _encoded(StoredMatch match) =>
      const JsonEncoder.withIndent('  ').convert(match.toJson());
}

// Keep isolate closures outside instance methods: sibling closures in those
// methods can otherwise capture publication callbacks and native resources.
Future<String> _encodeOffThread(StoredMatch match) => Isolate.run(
  () => const JsonEncoder.withIndent('  ').convert(match.toJson()),
);

Future<_DecodedCheckpoint> _decodeOffThread(
  String text,
  _ValidatedMoves? previous,
) => Isolate.run(() => _decodeCheckpoint(text, previous));

Future<String?> _text(String path) async {
  final observed = await observeFile(path);
  if (observed.status == 1) return null;
  if (observed.status != 0 || observed.bytes == null) {
    throw FileSystemException('Match file is unreadable or unsupported', path);
  }
  final bytes = observed.bytes!;
  try {
    return exactText(bytes);
  } on FormatException {
    throw FileSystemException('Match file is not valid UTF-8.', path);
  }
}

/// Strict read-only authority decoding. Inspection may compare [matchBpgn]
/// with the export without invoking the repairing [MatchFolder.list].
StoredMatch decodeMatchCheckpoint(String text) => _decodeMatch(text, null);

final class _ValidatedMoves {
  _ValidatedMoves(
    this.start,
    Iterable<String> games,
    this.config,
    Map<String, String> exports,
  ) : games = Set.unmodifiable(games),
      exports = Map.unmodifiable(exports);
  final String start;
  final Set<String> games;
  final String config;
  final Map<String, String> exports;
}

final class _DecodedCheckpoint {
  _DecodedCheckpoint(this.match, this.bpgn, this.validated);
  final StoredMatch match;
  final String bpgn;
  final _ValidatedMoves validated;
}

_DecodedCheckpoint _decodeCheckpoint(String text, _ValidatedMoves? previous) {
  final match = _decodeMatch(text, previous);
  final config = jsonEncode(match.config.toJson());
  final games = match.toJson()['games'] as List;
  final exports = <String, String>{};
  final bpgn = StringBuffer();
  for (var i = 0; i < games.length; i++) {
    final key = jsonEncode(games[i]);
    final cached = previous?.config == config ? previous?.exports[key] : null;
    final text = cached ?? gameBpgn(match.config, match.games[i]);
    exports[key] = text;
    bpgn.writeln(text);
  }
  return _DecodedCheckpoint(
    match,
    bpgn.toString(),
    _ValidatedMoves(
      match.config.startDualFen,
      match.games.map((game) => jsonEncode(game.moves)),
      config,
      exports,
    ),
  );
}

StoredMatch _decodeMatch(String text, _ValidatedMoves? previous) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text.startsWith('\ufeff') ? text.substring(1) : text);
  } on FormatException {
    // FormatException.source can contain the user's entire checkpoint.
    throw const FormatException('Match checkpoint is not valid JSON.');
  }
  final json = decoded;
  if (json is! Map<String, Object?> ||
      json['version'] != 1 ||
      json['config'] is! Map<String, Object?> ||
      json['games'] is! List ||
      !_date(json['createdAt']) ||
      (json['finishedAt'] != null && !_date(json['finishedAt'])) ||
      json['id'] is! String ||
      (json['error'] != null && json['error'] is! String) ||
      !MatchStatus.values.any((value) => value.name == json['status'])) {
    throw const FormatException('Unsupported or invalid match checkpoint.');
  }
  _config(json['config'] as Map<String, Object?>);
  final games = json['games'] as List;
  for (final game in games) {
    if (game is! Map<String, Object?> ||
        game['moves'] is! List ||
        !(game['moves'] as List).every((move) => move is String) ||
        !_strings(game, ['whiteName', 'blackName', 'detail']) ||
        !_integers(game, [
          'number',
          'whiteIndex',
          'blackIndex',
          'durationMs',
        ]) ||
        !_date(game['startedAt']) ||
        !MatchResult.values.any((value) => value.name == game['result']) ||
        !MatchEnding.values.any((value) => value.name == game['termination'])) {
      throw const FormatException('Invalid match game.');
    }
  }
  final match = StoredMatch.fromJson(json);
  final start = match.config.start;
  if (start == null ||
      match.games.any(
        (game) =>
            !(previous?.start == match.config.startDualFen &&
                previous!.games.contains(jsonEncode(game.moves))) &&
            replayGame(start, game.moves).moves.length != game.moves.length,
      )) {
    throw const FormatException('Invalid match position or moves.');
  }
  return match;
}

void _config(Map<String, Object?> config) {
  final teams = config['participants'];
  final variety = config['variety'];
  if (!_strings(config, ['name', 'startDualFen', 'openingLabel']) ||
      !_integers(config, [
        'games',
        'maxPlies',
        'hashMb',
        'batchSize',
        'seed',
      ]) ||
      config['alternateSeats'] is! bool ||
      !['ahead', 'level', 'behind'].contains(config['timeStance']) ||
      teams is! List ||
      teams.length != 2 ||
      variety is! Map<String, Object?> ||
      !_integers(variety, ['plies', 'lines']) ||
      variety['window'] is! num) {
    throw const FormatException('Invalid match configuration.');
  }
  for (final team in teams) {
    if (team is! Map<String, Object?> ||
        team['name'] is! String ||
        team['budget'] is! Map<String, Object?>) {
      throw const FormatException('Invalid match participant.');
    }
    final budget = team['budget'] as Map<String, Object?>;
    final nodes = budget['nodes'];
    final time = budget['movetimeMs'];
    if (!((nodes is int && nodes > 0 && time == null) ||
        (time is int && time > 0 && nodes == null))) {
      throw const FormatException('Invalid match budget.');
    }
  }
}

bool _strings(Map<String, Object?> value, List<String> keys) =>
    keys.every((key) => value[key] is String);
bool _integers(Map<String, Object?> value, List<String> keys) =>
    keys.every((key) => value[key] is int);
bool _date(Object? value) =>
    value is String && DateTime.tryParse(value) != null;
