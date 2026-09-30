import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../chess/players/player.dart';
import '../chess/tactics/game_ids.dart';
import '../diagnostics/log.dart';

/// Read-only discovery of the old analysis corpus. The live manifest wins
/// over retained flat backups, including a tombstone. No old cache is changed.
/// An unreadable manifest or flat file is logged and skipped.
Future<List<Player>> savedPlayers(Directory root) async {
  if (!await root.exists()) return const [];
  final found = <String, Player>{};
  final hidden = <String>{};
  final entries = await root.list().toList();
  for (final entry in entries.whereType<Directory>()) {
    final manifest = File(p.join(entry.path, 'current.json'));
    try {
      if (!await manifest.exists()) continue;
      final data = jsonDecode(await manifest.readAsString());
      final info = data is Map ? data['player'] : null;
      if (data is! Map ||
          info is! Map ||
          info['platform'] is! String ||
          info['username'] is! String)
        throw const FormatException('A player manifest has no identity.');
      final key = '${info['platform']}:${info['username']}'.toLowerCase();
      hidden.add(key);
      if (data['version'] != 1)
        throw const FormatException(
          'An older player corpus uses an unsupported manifest version.',
        );
      if (data['deleted'] == true) continue;
      final revision = data['revision'];
      if (revision is! String ||
          !RegExp(r'^\d+-[a-f0-9]{64}$').hasMatch(revision))
        throw const FormatException(
          'A player manifest has an invalid revision.',
        );
      final path = p.join(entry.path, 'versions', revision, 'games.pgn');
      found[key] = _player(info, path, p.basename(entry.path));
    } on FormatException catch (error) {
      log.w('skip saved player ${manifest.path}', error);
    } on FileSystemException catch (error) {
      log.w('skip saved player ${manifest.path}', error);
    }
  }
  for (final file in entries.whereType<File>()) {
    if (p.extension(file.path) != '.json') continue;
    try {
      // Identity files are tiny; the big ones are derived analysis caches.
      if (await file.length() > _maxIdentityBytes) continue;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map ||
          raw['platform'] is! String ||
          raw['username'] is! String)
        continue;
      final key = '${raw['platform']}:${raw['username']}'.toLowerCase();
      if (hidden.contains(key)) continue;
      final path = p.setExtension(file.path, '.pgn');
      if (await File(path).exists())
        found[key] = _player(raw, path, p.basenameWithoutExtension(file.path));
    } on FormatException catch (error) {
      log.w('skip saved player ${file.path}', error);
    } on FileSystemException catch (error) {
      log.w('skip saved player ${file.path}', error);
    }
  }
  return found.values.toList();
}

const _maxIdentityBytes = 256 * 1024;

Player _player(Map info, String path, String key) {
  final names = (info['username'] as String)
      .split(';')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  if (names.isEmpty) throw const FormatException('A saved player has no name.');
  final accounts = <String, Set<String>>{};
  for (final site in GameSite.values) {
    accounts[site.name] = {
      if (info['platform'] == site.name) info['username'] as String,
      for (final a in info['accounts'] is List ? info['accounts'] as List : [])
        if (a is Map && a['platform'] == site.name && a['username'] is String)
          a['username'] as String,
    };
  }
  return Player({
    ...Player.create(names.first).fields,
    'aliases': names.skip(1).toList(),
    'pgn_files': [path],
    'game_sets': [key],
    for (final a in accounts.entries) a.key: a.value.join(', '),
  });
}
