import 'dart:convert';
import 'dart:io';

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
  MatchFolder(String root, {this.publish = replaceFile})
    : _configuredRoot = Directory(p.normalize(p.absolute(root))),
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

  /// `Documents/bughouse_matches`.
  final String root;

  static const _metadata = 'match.json';
  static const _bpgn = 'games.bpgn';

  @override
  Future<List<StoredMatch>> list() async {
    _checkRoot();
    final folder = Directory(root);
    if (!await folder.exists()) return const [];
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
    StoredMatch match;
    try {
      final text = await _text(p.join(folder, _metadata));
      if (text == null) return null;
      match = decodeMatchCheckpoint(text);
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
    await requireUnusedRecoveryStage(p.join(folder, _metadata));
    await _export(folder, match);
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

  Future<void> _export(String folder, StoredMatch match) async {
    final path = p.join(folder, _bpgn);
    final expected = matchBpgn(match);
    final current = await _text(path);
    await requireUnusedRecoveryStage(path);
    if (current != expected) await publish(path, utf8.encode(expected));
  }

  @override
  Future<MatchCreate> create(MatchConfig config, DateTime now) async {
    try {
      _checkRoot();
      await Directory(root).create(recursive: true);
      final id = await _freeName(config.name);
      await Directory(p.join(root, id)).create();
      final match = StoredMatch(
        id: id,
        config: config,
        createdAt: now,
        status: MatchStatus.pending,
      );
      await createFileExclusively(
        p.join(root, id, _metadata),
        utf8.encode(_encoded(match)),
      );
      return MatchCreated(match);
    } on FileSystemException catch (error) {
      log.e('create a bughouse match in $root', error);
      return MatchCreateFailed(error.message);
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
      final after = _encoded(match);
      decodeMatchCheckpoint(after);
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
          decodeMatchCheckpoint(current);
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
          await requireUnusedRecoveryStage(file);
        }
        await publish(path, utf8.encode(after));
        await publish(p.join(folder, _bpgn), utf8.encode(matchBpgn(match)));
      });
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
    for (var n = 2; await Directory(p.join(root, candidate)).exists(); n++) {
      candidate = '$base-$n';
    }
    return candidate;
  }

  static String _encoded(StoredMatch match) =>
      const JsonEncoder.withIndent('  ').convert(match.toJson());
}

Future<String?> _text(String path) async {
  final observed = await observeFile(path);
  if (observed.status == 1) return null;
  if (observed.status != 0 || observed.bytes == null) {
    throw FileSystemException('Match file is unreadable or unsupported', path);
  }
  final bytes = observed.bytes!;
  return '${bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf ? '\ufeff' : ''}${utf8.decode(bytes)}';
}

/// Strict read-only authority decoding. Inspection may compare [matchBpgn]
/// with the export without invoking the repairing [MatchFolder.list].
StoredMatch decodeMatchCheckpoint(String text) {
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
