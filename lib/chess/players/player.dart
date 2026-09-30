import 'dart:convert';
import 'dart:math';

import '../tactics/game_ids.dart';

String playerId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${Random.secure().nextInt(1 << 32).toRadixString(36)}';

/// The shared directory format, including fields written by other app versions.
/// Edits replace only the explicitly changed fields.
final class Player {
  Player(Map<String, Object?> fields) : fields = Map.unmodifiable(fields);
  final Map<String, Object?> fields;
  String get id => fields['id'] as String;
  String get name => fields['name'] as String? ?? '';
  String text(String key) => fields[key]?.toString() ?? '';
  List<String> strings(String key) =>
      (fields[key] as List? ?? const []).whereType<String>().toList();
  List<String> get names => [
    name,
    ...strings('aliases'),
    for (final a in accounts) a.username,
  ];
  List<({GameSite site, String username})> get accounts => [
    for (final site in GameSite.values)
      for (final name in text(site.name).split(RegExp(r'[,;\s]+')))
        if (name.isNotEmpty) (site: site, username: name),
  ];
  List<String> get files => strings('pgn_files');
  String get search =>
      '$name ${text('uscf_id')} ${text('fide_id')} ${names.join(' ')} ${text('notes')}'
          .toLowerCase();
  Player edited(Map<String, Object?> changes) => Player({
    ...fields,
    ...changes,
    'updated_at': DateTime.now().toIso8601String(),
  });
  factory Player.create(String name) {
    final now = DateTime.now().toIso8601String();
    return Player({
      'id': playerId(),
      'name': name.trim(),
      'created_at': now,
      'updated_at': now,
    });
  }
}

final class PlayerGroup {
  PlayerGroup(Map<String, Object?> fields) : fields = Map.unmodifiable(fields);
  final Map<String, Object?> fields;
  String get id => fields['id'] as String;
  String get name => fields['name'] as String? ?? '';
  List<Map<String, Object?>> get entries => [
    for (final e in fields['entries'] as List? ?? const [])
      Map<String, Object?>.from(e as Map),
  ];
  bool contains(String id) => entries.any((e) => e['person'] == id);
  bool prepared(String id) =>
      entries.any((e) => e['person'] == id && e['prepared'] == true);
  PlayerGroup edited(Map<String, Object?> changes) => PlayerGroup({
    ...fields,
    ...changes,
    'updated_at': DateTime.now().toIso8601String(),
  });
  PlayerGroup member(String id, {bool? prepared, bool remove = false}) =>
      edited({
        'entries': [
          for (final e in entries)
            if (e['person'] != id)
              e
            else if (!remove)
              {...e, if (prepared != null) 'prepared': prepared},
          if (!remove && !contains(id))
            {'person': id, 'prepared': prepared ?? false},
        ],
      });
  factory PlayerGroup.create(String name) => PlayerGroup({
    'format': 'chess-auto-prep/tournament@1',
    'id': playerId(),
    'name': name.trim(),
    'entries': <Object>[],
    'created_at': DateTime.now().toIso8601String(),
  });
}

/// A pasted roster is previewed before anything is committed. JSON preserves
/// the directory's extra metadata; tables require named columns.
List<Player> readPlayerList(String text) => _looksJson(text.trim())
    ? _jsonPlayers(text.trim())
    : _tablePlayers(text.trim());
bool _looksJson(String text) => text.startsWith('{') || text.startsWith('[');
List<Player> _jsonPlayers(String text) {
  final json = jsonDecode(text);
  final rows = json is List
      ? json
      : (json['people'] ?? json['opponents'] ?? json['players']);
  if (rows is! List)
    throw const FormatException('Use a player list or an opponents export.');
  return [
    for (final row in rows)
      if (row is Map) _imported(Map<String, Object?>.from(row)),
  ];
}

List<Player> _tablePlayers(String text) {
  final lines = text.split('\n').where((s) => s.trim().isNotEmpty).toList();
  if (lines.length < 2)
    throw const FormatException(
      'Include column headings, such as Name, Rating, Chess.com and Lichess.',
    );
  final delimiter = lines.first.contains('\t')
      ? '\t'
      : lines.first.contains('|')
      ? '|'
      : ',';

  final headers = _cells(lines.first, delimiter)
      .map((s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z]'), ''))
      .map(
        (s) => switch (s) {
          'player' || 'name' => 'name',
          'uscf' || 'uscfid' || 'uschessid' => 'uscf_id',
          'chesscom' || 'chesscomaccounts' => 'chesscom',
          'lichess' || 'lichessaccounts' => 'lichess',
          'rating' => 'rating',
          'notes' => 'notes',
          'fideid' => 'fide_id',
          _ => '',
        },
      )
      .toList();
  if (!headers.contains('name'))
    throw const FormatException('Include a Name column.');
  return lines
      .skip(1)
      .where((line) => !RegExp(r'^[\s|:\-]+$').hasMatch(line))
      .map((line) => _tablePlayer(_cells(line, delimiter), headers))
      .toList();
}

Player _imported(Map<String, Object?> fields) {
  final name = fields['name']?.toString().trim() ?? '';
  if (name.isEmpty) throw const FormatException('Every player needs a name.');
  return Player({
    ...Player.create(name).fields,
    ...fields,
    'id': fields['id'] is String ? fields['id'] : playerId(),
    for (final key in ['rating', 'fide_id'])
      if (fields.containsKey(key)) key: int.tryParse('${fields[key]}'),
  });
}

List<String> _cells(String line, String delimiter) {
  final values = <String>[];
  final buffer = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"') {
      if (quoted && i + 1 < line.length && line[i + 1] == '"') {
        buffer.write('"');
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (c == delimiter && !quoted) {
      values.add(buffer.toString().trim());
      buffer.clear();
    } else {
      buffer.write(c);
    }
  }
  values.add(buffer.toString().trim());
  if (delimiter == '|') {
    if (values.first.isEmpty) values.removeAt(0);
    if (values.last.isEmpty) values.removeLast();
  }
  return values;
}

bool samePlayer(Player a, Player b) {
  final idA = a.text('uscf_id'), idB = b.text('uscf_id');
  if (idA.isNotEmpty && idB.isNotEmpty) return idA == idB;
  if (a.accounts.any(
    (x) => b.accounts.any(
      (y) =>
          x.site == y.site &&
          x.username.toLowerCase() == y.username.toLowerCase(),
    ),
  ))
    return true;
  return a.id == b.id ||
      a.names.any(
        (x) => b.names.any((y) => x.toLowerCase() == y.toLowerCase()),
      );
}

Player _tablePlayer(List<String> cells, List<String> headers) => _imported({
  for (final (i, value) in cells.indexed)
    if (i < headers.length && headers[i].isNotEmpty) headers[i]: value,
});
