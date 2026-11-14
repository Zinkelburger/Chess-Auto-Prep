import 'dart:convert';
import 'dart:math';

import '../tactics/game_ids.dart';

String playerId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${Random.secure().nextInt(1 << 32).toRadixString(36)}';

/// A study linked to a person, or one chapter of it; [at] is where the link
/// is in the person's `studies`.
typedef StudyLink = ({String path, String? chapter, int at});

/// The shared directory format, including fields written by other app versions.
/// Edits replace only the explicitly changed fields. A field holding a value
/// of the wrong type — hand edited, or written by another tool — reads as
/// absent and is kept as it is; [unreadFields] names it for the log.
final class Player {
  Player(Map<String, Object?> fields) : fields = Map.unmodifiable(fields);
  final Map<String, Object?> fields;
  String get id => fields['id'] as String;
  String get name => _string(fields['name']) ?? '';
  String text(String key) => fields[key]?.toString() ?? '';
  List<String> strings(String key) => switch (fields[key]) {
    final List list => list.whereType<String>().toList(),
    _ => const [],
  };

  /// The studies linked to the person. A link without a path is left out; a
  /// chapter that is not text reads as the whole study.
  List<StudyLink> get studies => [
    if (fields['studies'] case final List links)
      for (final (at, link) in links.indexed)
        if (link case final Map map
            when map['path'] is String && map['path'] != '')
          (
            path: map['path'] as String,
            chapter: _string(map['chapter']),
            at: at,
          ),
  ];

  /// This person with [path] linked; whatever `studies` held is kept.
  Player withStudy(String path) => edited({
    'studies': [
      ..._kept(fields['studies']),
      {'path': path},
    ],
  });

  /// This person with [added] in the list field [key]. Whatever [key] held
  /// is kept: a value that is not a list stays as one entry, and entries
  /// that are not text stay too.
  Player withStrings(String key, Iterable<String> added) {
    final kept = _kept(fields[key]);
    return edited({
      key: [
        ...kept,
        for (final text in {...added})
          if (!kept.contains(text)) text,
      ],
    });
  }

  /// This person without [link]; every other entry is kept as it was.
  Player withoutStudy(StudyLink link) => edited({
    'studies': [
      for (final (at, other) in _kept(fields['studies']).indexed)
        if (at != link.at) other,
    ],
  });

  /// The fields that hold a value of a type this app does not read them as,
  /// so read as absent.
  List<String> get unreadFields => [
    for (final key in const [
      'aliases',
      'pgn_files',
      'dismissed_findings',
      'studies',
    ])
      if (fields[key] case final value? when value is! List) key,
    if (fields['studies'] case final List links)
      for (final (at, link) in links.indexed)
        if (link is! Map || link['path'] is! String)
          'studies[$at]'
        else if (link['chapter'] case final chapter? when chapter is! String)
          'studies[$at].chapter',
    for (final key in const ['download', 'lookup'])
      if (fields[key] case final value? when value is! Map) key,
    if (fields['download'] case final Map download) ...[
      for (final key in const ['max', 'months'])
        if (download[key] case final value? when value is! int) 'download.$key',
      if (download['speeds'] case final value? when value is! List)
        'download.speeds',
    ],
  ];
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

/// A tournament or other group of people. As with [Player], a field of the
/// wrong type reads as absent and is kept as it is.
final class PlayerGroup {
  PlayerGroup(Map<String, Object?> fields) : fields = Map.unmodifiable(fields);
  final Map<String, Object?> fields;
  String get id => fields['id'] as String;
  String get name => _string(fields['name']) ?? '';

  /// The event date as written (`YYYY-MM-DD`), or null.
  String? get date => _string(fields['date']);
  int? get rounds => switch (fields['rounds']) {
    final int rounds => rounds,
    _ => null,
  };

  /// The group's prep study, or empty.
  String get study => _string(fields['study']) ?? '';

  /// The fields that hold a value of a type this app does not read them as,
  /// so read as absent.
  List<String> get unreadFields => [
    for (final key in const ['name', 'date', 'study'])
      if (fields[key] case final value? when value is! String) key,
    if (fields['rounds'] case final value? when value is! int) 'rounds',
  ];
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
              {...e, 'prepared': ?prepared},
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

String? _string(Object? value) => value is String ? value : null;

/// [value] as list entries to keep: a list's entries, or a single value of
/// another type as the only one, so an edit beside it loses nothing.
List<Object?> _kept(Object? value) => switch (value) {
  final List list => list,
  null => const [],
  final other => [other],
};

/// A pasted roster is previewed before anything is committed. JSON preserves
/// the directory's extra metadata; tables require named columns.
List<Player> readPlayerList(String text) => _looksJson(text.trim())
    ? _jsonPlayers(text.trim())
    : _tablePlayers(text.trim());
bool _looksJson(String text) => text.startsWith('{') || text.startsWith('[');
List<Player> _jsonPlayers(String text) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    throw const FormatException('That JSON cannot be read.');
  }
  final rows = json is Map
      ? json['people'] ?? json['opponents'] ?? json['players']
      : json;
  if (rows is! List) {
    throw const FormatException('Use a player list or an opponents export.');
  }
  return [
    for (final row in rows)
      if (row is Map) _imported(Map<String, Object?>.from(row)),
  ];
}

List<Player> _tablePlayers(String text) {
  final lines = text.split('\n').where((s) => s.trim().isNotEmpty).toList();
  if (lines.length < 2) {
    throw const FormatException(
      'Include column headings, such as Name, Rating, Chess.com and Lichess.',
    );
  }
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
  if (!headers.contains('name')) {
    throw const FormatException('Include a Name column.');
  }
  return lines
      .skip(1)
      .where((line) => !RegExp(r'^[\s|:\-]+$').hasMatch(line))
      .map((line) => _cells(line, delimiter))
      // A spreadsheet's trailing empty row, `,,,`, is no player.
      .where((cells) => cells.any((cell) => cell.isNotEmpty))
      .map((cells) => _tablePlayer(cells, headers))
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

/// The person in [people] that [incoming] is: the one with its US Chess ID,
/// else one sharing an account, else one of the same name or alias. A
/// person whose different US Chess ID rules them out is never it.
Player? matchingPlayer(Iterable<Player> people, Player incoming) {
  final candidates = people.where((p) => samePlayer(p, incoming)).toList();
  final id = incoming.text('uscf_id');
  return candidates
          .where((p) => id.isNotEmpty && p.text('uscf_id') == id)
          .firstOrNull ??
      candidates.where((p) => _shareAccount(p, incoming)).firstOrNull ??
      candidates.firstOrNull;
}

bool _shareAccount(Player a, Player b) => a.accounts.any(
  (x) => b.accounts.any(
    (y) =>
        x.site == y.site &&
        x.username.toLowerCase() == y.username.toLowerCase(),
  ),
);

bool samePlayer(Player a, Player b) {
  final idA = a.text('uscf_id'), idB = b.text('uscf_id');
  if (idA.isNotEmpty && idB.isNotEmpty) return idA == idB;
  if (_shareAccount(a, b)) return true;
  return a.id == b.id ||
      a.names.any(
        (x) => b.names.any((y) => x.toLowerCase() == y.toLowerCase()),
      );
}

Player _tablePlayer(List<String> cells, List<String> headers) => _imported({
  for (final (i, value) in cells.indexed)
    if (i < headers.length && headers[i].isNotEmpty) headers[i]: value,
});
