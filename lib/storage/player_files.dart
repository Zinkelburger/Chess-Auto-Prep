import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../chess/players/player.dart';
import '../diagnostics/log.dart';
import 'atomic_write.dart';
import 'file_lock.dart';

typedef PlayerDirectory = ({
  List<Player> players,
  List<PlayerGroup> groups,
  List<String> warnings,
});

abstract interface class PlayerStore {
  Future<PlayerDirectory> read();
  Future<void> savePlayer(Player player, {Player? expected});
  Future<void> saveGroup(PlayerGroup group, {PlayerGroup? expected});
  Future<void> removePlayer(Player player);
  Future<void> removeGroup(PlayerGroup group);
}

/// A save or removal refused because the row is no longer what the caller
/// read: another window changed it. Retrying the same edit cannot succeed.
final class PlayerConflict implements Exception {
  const PlayerConflict(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Updates the shared formats under their folder lock, rereading before every
/// edit. A stale row is refused; unrelated rows and unknown fields survive.
final class PlayerFiles implements PlayerStore {
  PlayerFiles(this.root);
  final Directory root;
  Directory get _groups => Directory(p.join(root.path, 'tournaments'));
  static const _equal = DeepCollectionEquality();

  Future<Map<String, Object?>> _read(String path, String format) async {
    final file = File(path);
    if (!await file.exists()) return {'format': format};
    final raw = jsonDecode(await file.readAsString());
    if (raw is! Map || (raw['format'] != null && raw['format'] != format)) {
      throw const FormatException(
        'This player file uses an unsupported format.',
      );
    }
    return Map<String, Object?>.from(raw);
  }

  String get _people => p.join(root.path, 'people.json');

  /// The rows of people.json; a file whose rows are not a list is not one
  /// this app may write over.
  static List<Object?> _list(Map<String, Object?> json) {
    final rows = json['people'];
    if (rows == null) return [];
    if (rows is! List) {
      throw const FormatException('The people in this file are not a list.');
    }
    return rows;
  }

  static Object? _id(Object? row) => row is Map ? row['id'] : null;

  /// Why [row] is not a player this app can show, or null when it is one.
  static String? _problem(Object? row) {
    if (row is! Map) return 'a row is not an object';
    final id = row['id'];
    if (id is! String || id.isEmpty) return 'a row has no ID';
    if (row['name'] is! String?) {
      return 'player $id has a name that is not text';
    }
    return null;
  }

  static bool _readable(Object? row) => _problem(row) == null;

  /// The players [json] holds, the first row of each ID, and how many rows
  /// were left out and why. The rows left out stay in the file: a save
  /// writes them back untouched.
  static ({List<Player> players, int unread, String reasons}) _rows(
    Map<String, Object?> json,
  ) {
    final players = <Player>[];
    final seen = <String>{};
    final reasons = <String>[];
    for (final row in _list(json)) {
      final problem =
          _problem(row) ??
          (seen.contains(_id(row))
              ? 'player ${_id(row)} is listed twice'
              : null);
      if (problem != null) {
        reasons.add(problem);
        continue;
      }
      seen.add(_id(row)! as String);
      players.add(Player(Map<String, Object?>.from(row! as Map)));
    }
    return (
      players: players,
      unread: reasons.length,
      reasons: reasons.join('; '),
    );
  }

  String _group(String id) {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
      throw const FormatException('Invalid group ID.');
    }
    return p.join(_groups.path, '$id.json');
  }

  Future<void> _write(String path, Map<String, Object?> data) => replaceFile(
    path,
    utf8.encode('${const JsonEncoder.withIndent('  ').convert(data)}\n'),
  );

  @override
  Future<PlayerDirectory> read() async {
    final warnings = <String>[];
    var players = <Player>[];
    try {
      final json = await _read(_people, 'chess-auto-prep/people@1');
      final rows = _rows(json);
      players = rows.players;
      if (rows.unread > 0) {
        log.w(
          'read people.json',
          '${rows.unread} unreadable rows left in place: ${rows.reasons}',
        );
        warnings.add(
          rows.unread == 1
              ? '1 player in people.json could not be read. It is kept in '
                    'the file as it is.'
              : '${rows.unread} players in people.json could not be read. '
                    'They are kept in the file as they are.',
        );
      }
    } on Object catch (e) {
      // The file as a whole: its players stay out until it reads again, and
      // every save refuses it, so nothing writes over what it holds.
      log.w('read people.json', e);
      warnings.add('Could not read people.json: $e');
    }
    final groups = <PlayerGroup>[];
    if (!await _groups.exists()) {
      return (players: players, groups: groups, warnings: warnings);
    }
    await for (final file in _groups.list()) {
      if (file is! File || p.extension(file.path) != '.json') continue;
      try {
        final data = await _read(file.path, 'chess-auto-prep/tournament@1');
        data['id'] ??= p.basenameWithoutExtension(file.path);
        final group = PlayerGroup(data);
        if (group.id != p.basenameWithoutExtension(file.path) ||
            group.entries.any((e) => e['person'] is! String)) {
          throw const FormatException('Invalid group or member ID.');
        }
        groups.add(group);
      } on Object catch (e) {
        warnings.add('Could not read ${p.basename(file.path)}: $e');
      }
    }
    return (players: players, groups: groups, warnings: warnings);
  }

  @override
  Future<void> savePlayer(Player player, {Player? expected}) =>
      _changePlayer(player.id, player, expected);
  @override
  Future<void> removePlayer(Player player) =>
      _changePlayer(player.id, null, player);
  Future<void> _changePlayer(String id, Player? next, Player? expected) async {
    await root.create(recursive: true);
    await withDirectoryLock(root, () async {
      final data = await _read(_people, 'chess-auto-prep/people@1');
      final rows = _list(data);
      // The row this directory reads under [id]: the first readable one.
      // Every other row, readable or not, is written back as it was.
      final at = rows.indexWhere((row) => _readable(row) && _id(row) == id);
      final current = at < 0
          ? null
          : Map<String, Object?>.from(rows[at] as Map);
      if (_equal.equals(current, next?.fields)) return; // Lost acknowledgement.
      if (!_equal.equals(current, expected?.fields)) {
        throw const PlayerConflict(
          'This player changed in another window. Reload before editing.',
        );
      }
      // An edit stays where its row was, so the first row of its ID is still
      // this one and a later duplicate never takes its place.
      data['people'] = [
        for (final (i, row) in rows.indexed)
          if (i != at) row else if (next != null) next.fields,
        if (at < 0 && next != null) next.fields,
      ];
      await _write(_people, data);
    });
  }

  @override
  Future<void> saveGroup(PlayerGroup group, {PlayerGroup? expected}) async {
    await _groups.create(recursive: true);
    await withDirectoryLock(_groups, () async {
      final path = _group(group.id);
      final current = await File(path).exists()
          ? await _read(path, 'chess-auto-prep/tournament@1')
          : null;
      if (current != null) current['id'] ??= group.id;
      if (_equal.equals(current, group.fields)) return;
      if (!_equal.equals(current, expected?.fields)) {
        throw const PlayerConflict(
          'This group changed in another window. Reload before editing.',
        );
      }
      await _write(path, group.fields);
    });
  }

  @override
  Future<void> removeGroup(PlayerGroup group) async {
    await withDirectoryLock(_groups, () async {
      final path = _group(group.id);
      if (!await File(path).exists()) return;
      final current = await _read(path, 'chess-auto-prep/tournament@1');
      current['id'] ??= group.id;
      if (!_equal.equals(current, group.fields)) {
        throw const PlayerConflict(
          'This group changed in another window. Reload before removing it.',
        );
      }
      final trash = Directory(p.join(root.path, '.removed'));
      await trash.create(recursive: true);
      await movePathNoReplace(
        path,
        p.join(trash.path, '${group.id}-${playerId()}.json'),
      );
    });
  }
}

final class MemoryPlayers implements PlayerStore {
  final players = <String, Player>{};
  final groups = <String, PlayerGroup>{};
  @override
  Future<PlayerDirectory> read() async => (
    players: players.values.toList(),
    groups: groups.values.toList(),
    warnings: const <String>[],
  );
  @override
  Future<void> savePlayer(Player player, {Player? expected}) async {
    players[player.id] = player;
  }

  @override
  Future<void> saveGroup(PlayerGroup group, {PlayerGroup? expected}) async {
    groups[group.id] = group;
  }

  @override
  Future<void> removePlayer(Player player) async {
    players.remove(player.id);
  }

  @override
  Future<void> removeGroup(PlayerGroup group) async {
    groups.remove(group.id);
  }
}
