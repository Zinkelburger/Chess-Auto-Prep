/// One person in the opponents directory: who they are, where their games
/// live online, and what you have written down about them.
///
/// This is the global half of the sheet the feature replaces (name · USCF ID ·
/// Chess.com · Lichess · notes · file). A person is entered once and then
/// listed in any number of tournaments; the per-tournament half is
/// [TournamentEntry].
library;

import 'dart:math';

import '../../../models/analysis_player_info.dart';
import '../../../services/opponent_list.dart';

/// A short, sortable, collision-safe id for a new record.
String _newRecordId() {
  final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final salt = Random().nextInt(1 << 20).toRadixString(36).padLeft(4, '0');
  return '$stamp$salt';
}

/// [value] trimmed, or null when it is null or blank.
String? _blankToNull(String? value) {
  final trimmed = value?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

/// A directory entry. Immutable; every edit goes through [copyWith] and the
/// store stamps `updatedAt` on save.
///
/// Serialized as one row of `people.json`; [toJson] and [fromJson] are the
/// on-disk format and must stay backwards compatible.
class PersonRecord {
  final String id;
  final String name;
  final String? uscfId;
  final String? chesscom;
  final String? lichess;

  /// Their current rating, from whichever source the user trusts (US Chess
  /// lookup, the entry list, or typed in).
  final int? rating;
  final String? title;

  /// Other spellings of the name (`Denis Shmeliov` for `Denys Shmelov`),
  /// matched by search and import like the name itself.
  final List<String> aliases;

  /// FIDE ID, the key master-games records carry under every spelling.
  final int? fideId;

  /// Keys this version does not model — the MCP tooling's `lookup` report
  /// among them — written back unchanged so a save never drops them.
  final Map<String, dynamic> extra;

  /// Free text. Global: carries across tournaments, unlike the prep file's
  /// lines which are also global but live in a study.
  final String notes;

  /// The study that is this person's prep file, once one has been created.
  final String? prepFilePath;

  /// Explicit links survive display-name and account edits.
  final List<String> gameSetKeys;
  final List<PlayerStudyLink> studyLinks;

  final DateTime createdAt;
  final DateTime updatedAt;

  const PersonRecord({
    required this.id,
    required this.name,
    this.uscfId,
    this.chesscom,
    this.lichess,
    this.rating,
    this.title,
    this.aliases = const [],
    this.fideId,
    this.extra = const {},
    this.notes = '',
    this.prepFilePath,
    this.gameSetKeys = const [],
    this.studyLinks = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  static const _knownKeys = {
    'id',
    'name',
    'uscf_id',
    'chesscom',
    'lichess',
    'rating',
    'title',
    'aliases',
    'fide_id',
    'notes',
    'prep_file',
    'game_sets',
    'studies',
    'created_at',
    'updated_at',
  };

  /// A fresh person, id and timestamps minted now.
  factory PersonRecord.create({
    required String name,
    String? uscfId,
    String? chesscom,
    String? lichess,
    int? rating,
    String? title,
    String notes = '',
  }) {
    final now = DateTime.now();
    return PersonRecord(
      id: _newRecordId(),
      name: name.trim(),
      uscfId: _blankToNull(uscfId),
      chesscom: _blankToNull(chesscom),
      lichess: _blankToNull(lichess),
      rating: rating,
      title: _blankToNull(title),
      notes: notes,
      createdAt: now,
      updatedAt: now,
    );
  }

  factory PersonRecord.fromJson(Map<String, dynamic> json) {
    final now = DateTime.now();
    return PersonRecord(
      id: json['id'] as String? ?? _newRecordId(),
      name: (json['name'] as String? ?? '').trim(),
      uscfId: _blankToNull(json['uscf_id']?.toString()),
      chesscom: _blankToNull(json['chesscom'] as String?),
      lichess: _blankToNull(json['lichess'] as String?),
      rating: (json['rating'] as num?)?.toInt(),
      title: _blankToNull(json['title'] as String?),
      aliases: [
        for (final alias in json['aliases'] as List? ?? const [])
          if (alias is String && alias.trim().isNotEmpty) alias.trim(),
      ],
      fideId: switch (json['fide_id']) {
        final num id => id.toInt(),
        final String id => int.tryParse(id.trim()),
        _ => null,
      },
      extra: {
        for (final MapEntry(:key, :value) in json.entries)
          if (!_knownKeys.contains(key)) key: value,
      },
      notes: json['notes'] as String? ?? '',
      prepFilePath: _blankToNull(json['prep_file'] as String?),
      gameSetKeys: (json['game_sets'] as List? ?? const [])
          .whereType<String>()
          .toList(),
      studyLinks: [
        for (final link in json['studies'] as List? ?? const [])
          if (link is Map)
            PlayerStudyLink.fromJson(link.cast<String, dynamic>()),
      ],
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ?? now,
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ?? now,
    );
  }

  /// The same entry the opponent-list importer builds, so a person's game-set
  /// is one and the same whether they arrived by file or by hand.
  OpponentEntry get asOpponentEntry => OpponentEntry(
    name: name,
    chesscom: chesscom,
    lichess: lichess,
    rating: rating,
    title: title,
  );

  List<PlayerAccount> get accounts => asOpponentEntry.accounts;
  bool get hasAccount => accounts.isNotEmpty;

  /// The stored game-set name (`"Jane Doe; janed; jd_li"`) — see
  /// [OpponentEntry.playerName].
  String get playerName => asOpponentEntry.playerName;

  /// The Player Analysis entry whose games are this person's.
  AnalysisPlayerInfo toPlayerInfo({String? group, int monthsBack = 6}) =>
      asOpponentEntry.toPlayerInfo(
        group: group,
        maxGames: 100,
        monthsBack: monthsBack,
      );

  /// One line of handles for lists: `chess.com janed · lichess jd_li`.
  String get handlesLine => [
    if (chesscom != null) 'chess.com $chesscom',
    if (lichess != null) 'lichess $lichess',
  ].join(' · ');

  Map<String, dynamic> toJson() => {
    ...extra,
    'id': id,
    'name': name,
    if (uscfId != null) 'uscf_id': uscfId,
    if (chesscom != null) 'chesscom': chesscom,
    if (lichess != null) 'lichess': lichess,
    if (rating != null) 'rating': rating,
    if (title != null) 'title': title,
    if (aliases.isNotEmpty) 'aliases': aliases,
    if (fideId != null) 'fide_id': fideId,
    if (notes.isNotEmpty) 'notes': notes,
    if (prepFilePath != null) 'prep_file': prepFilePath,
    'game_sets': gameSetKeys,
    'studies': [for (final link in studyLinks) link.toJson()],
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  /// A copy with the given fields replaced. Blank strings count as "not
  /// given" and keep the current value; use the `clear…` flags to blank a
  /// field on purpose.
  PersonRecord copyWith({
    String? name,
    String? uscfId,
    bool clearUscfId = false,
    String? chesscom,
    bool clearChesscom = false,
    String? lichess,
    bool clearLichess = false,
    int? rating,
    bool clearRating = false,
    String? title,
    bool clearTitle = false,
    List<String>? aliases,
    String? notes,
    String? prepFilePath,
    bool clearPrepFilePath = false,
    List<String>? gameSetKeys,
    List<PlayerStudyLink>? studyLinks,
    DateTime? updatedAt,
  }) => PersonRecord(
    id: id,
    name: name?.trim() ?? this.name,
    uscfId: clearUscfId ? null : (_blankToNull(uscfId) ?? this.uscfId),
    chesscom: clearChesscom ? null : (_blankToNull(chesscom) ?? this.chesscom),
    lichess: clearLichess ? null : (_blankToNull(lichess) ?? this.lichess),
    rating: clearRating ? null : (rating ?? this.rating),
    title: clearTitle ? null : (_blankToNull(title) ?? this.title),
    aliases: aliases ?? this.aliases,
    fideId: fideId,
    extra: extra,
    notes: notes ?? this.notes,
    prepFilePath: clearPrepFilePath
        ? null
        : (_blankToNull(prepFilePath) ?? this.prepFilePath),
    gameSetKeys: gameSetKeys ?? this.gameSetKeys,
    studyLinks: studyLinks ?? this.studyLinks,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  @override
  String toString() => 'PersonRecord($id, $name)';
}

/// A whole PGN/study or a named chapter, opened directly from the player row.
class PlayerStudyLink {
  const PlayerStudyLink({required this.path, this.chapter});

  final String path;
  final String? chapter;

  factory PlayerStudyLink.fromJson(Map<String, dynamic> json) =>
      PlayerStudyLink(
        path: json['path'] as String,
        chapter: json['chapter'] as String?,
      );

  Map<String, dynamic> toJson() => {
    'path': path,
    if (chapter != null) 'chapter': chapter,
  };

  @override
  bool operator ==(Object other) =>
      other is PlayerStudyLink &&
      other.path == path &&
      other.chapter == chapter;

  @override
  int get hashCode => Object.hash(path, chapter);
}
