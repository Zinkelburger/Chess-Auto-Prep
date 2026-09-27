import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:path/path.dart' as p;

import '../chess/players/player.dart';
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
    if (raw is List && format == 'chess-auto-prep/people@1')
      return {'format': format, 'people': raw};
    if (raw is! Map || (raw['format'] != null && raw['format'] != format))
      throw const FormatException(
        'This player file uses an unsupported format.',
      );
    return Map<String, Object?>.from(raw);
  }

  String get _people => p.join(root.path, 'people.json');
  String _group(String id) {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id))
      throw const FormatException('Invalid group ID.');
    return p.join(_groups.path, '$id.json');
  }

  Future<void> _write(String path, Map<String, Object?> data) => replaceFile(
    path,
    utf8.encode('${const JsonEncoder.withIndent('  ').convert(data)}\n'),
  );

  @override
  Future<PlayerDirectory> read() async {
    final json = await _read(_people, 'chess-auto-prep/people@1');
    final players = [
      for (final row in json['people'] as List? ?? const [])
        Player(Map<String, Object?>.from(row as Map)),
    ];
    // Validate before allowing any edit of a malformed directory.
    if (players.any((p) => p.id.isEmpty) ||
        players.map((p) => p.id).toSet().length != players.length)
      throw const FormatException('Player IDs are missing or duplicated.');
    final groups = <PlayerGroup>[];
    final warnings = <String>[];
    if (await _groups.exists()) {
      await for (final file in _groups.list()) {
        if (file is! File || p.extension(file.path) != '.json') continue;
        try {
          final data = await _read(file.path, 'chess-auto-prep/tournament@1');
          data['id'] ??= p.basenameWithoutExtension(file.path);
          final group = PlayerGroup(data);
          if (group.id != p.basenameWithoutExtension(file.path) ||
              group.entries.any((e) => e['person'] is! String))
            throw const FormatException('Invalid group or member ID.');
          groups.add(group);
        } on Object catch (e) {
          warnings.add('Could not read ${p.basename(file.path)}: $e');
        }
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
      final rows = [
        for (final row in data['people'] as List? ?? const [])
          Map<String, Object?>.from(row as Map),
      ];
      final current = rows.where((row) => row['id'] == id).firstOrNull;
      if (_equal.equals(current, next?.fields)) return; // Lost acknowledgement.
      if (!_equal.equals(current, expected?.fields))
        throw StateError(
          'This player changed in another window. Reload before editing.',
        );
      data['people'] = [
        for (final row in rows)
          if (row['id'] != id) row,
        if (next != null) next.fields,
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
      if (!_equal.equals(current, expected?.fields))
        throw StateError(
          'This group changed in another window. Reload before editing.',
        );
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
      if (!_equal.equals(current, group.fields))
        throw StateError(
          'This group changed in another window. Reload before removing it.',
        );
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
