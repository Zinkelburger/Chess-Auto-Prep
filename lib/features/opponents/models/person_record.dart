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
String newRecordId() {
  final t = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final r = Random().nextInt(1 << 20).toRadixString(36).padLeft(4, '0');
  return '$t$r';
}

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

  /// Free text. Global: carries across tournaments, unlike the prep file's
  /// lines which are also global but live in a study.
  final String notes;

  /// The study that is this person's prep file, once one has been created.
  final String? prepFilePath;

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
    this.notes = '',
    this.prepFilePath,
    required this.createdAt,
    required this.updatedAt,
  });

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
      id: newRecordId(),
      name: name.trim(),
      uscfId: _clean(uscfId),
      chesscom: _clean(chesscom),
      lichess: _clean(lichess),
      rating: rating,
      title: _clean(title),
      notes: notes,
      createdAt: now,
      updatedAt: now,
    );
  }

  static String? _clean(String? s) {
    final t = s?.trim();
    return (t == null || t.isEmpty) ? null : t;
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
    'id': id,
    'name': name,
    if (uscfId != null) 'uscf_id': uscfId,
    if (chesscom != null) 'chesscom': chesscom,
    if (lichess != null) 'lichess': lichess,
    if (rating != null) 'rating': rating,
    if (title != null) 'title': title,
    if (notes.isNotEmpty) 'notes': notes,
    if (prepFilePath != null) 'prep_file': prepFilePath,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory PersonRecord.fromJson(Map<String, dynamic> json) {
    final now = DateTime.now();
    return PersonRecord(
      id: json['id'] as String? ?? newRecordId(),
      name: (json['name'] as String? ?? '').trim(),
      uscfId: _clean(json['uscf_id']?.toString()),
      chesscom: _clean(json['chesscom'] as String?),
      lichess: _clean(json['lichess'] as String?),
      rating: (json['rating'] as num?)?.toInt(),
      title: _clean(json['title'] as String?),
      notes: json['notes'] as String? ?? '',
      prepFilePath: _clean(json['prep_file'] as String?),
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ?? now,
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ?? now,
    );
  }

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
    String? notes,
    String? prepFilePath,
    bool clearPrepFilePath = false,
    DateTime? updatedAt,
  }) => PersonRecord(
    id: id,
    name: name?.trim() ?? this.name,
    uscfId: clearUscfId ? null : (_clean(uscfId) ?? this.uscfId),
    chesscom: clearChesscom ? null : (_clean(chesscom) ?? this.chesscom),
    lichess: clearLichess ? null : (_clean(lichess) ?? this.lichess),
    rating: clearRating ? null : (rating ?? this.rating),
    title: clearTitle ? null : (_clean(title) ?? this.title),
    notes: notes ?? this.notes,
    prepFilePath: clearPrepFilePath
        ? null
        : (_clean(prepFilePath) ?? this.prepFilePath),
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  @override
  String toString() => 'PersonRecord($id, $name)';
}
