/// A tournament you are preparing for (or once prepared for): its name, when
/// it is, and who is in the field — each entry pointing at a [PersonRecord]
/// in the directory plus the facts that belong to this event only.
library;

/// One opponent in one tournament's field.
class TournamentEntry {
  final String personId;

  /// Rating on the entry list, which may differ from the person's current
  /// rating in the directory.
  final int? rating;

  /// P(you face them), from a pairing simulation. Null when unknown.
  final double? pairingProb;
  final int? likelyRound;

  /// Ticked by the user once their prep is done — the checklist that makes
  /// "next opponent" mean something.
  final bool prepared;

  const TournamentEntry({
    required this.personId,
    this.rating,
    this.pairingProb,
    this.likelyRound,
    this.prepared = false,
  });

  /// Rating, odds and round as one short line; empty when none are known.
  String get summary => [
    if (rating != null) '$rating',
    if (pairingProb != null) '${(pairingProb! * 100).round()}% to face',
    if (likelyRound != null) 'likely round $likelyRound',
  ].join(' · ');

  Map<String, dynamic> toJson() => {
    'person': personId,
    if (rating != null) 'rating': rating,
    if (pairingProb != null) 'pairing_prob': pairingProb,
    if (likelyRound != null) 'likely_round': likelyRound,
    if (prepared) 'prepared': true,
  };

  factory TournamentEntry.fromJson(Map<String, dynamic> json) =>
      TournamentEntry(
        personId: json['person'] as String? ?? '',
        rating: (json['rating'] as num?)?.toInt(),
        pairingProb: (json['pairing_prob'] as num?)?.toDouble(),
        likelyRound: (json['likely_round'] as num?)?.toInt(),
        prepared: json['prepared'] == true,
      );

  TournamentEntry copyWith({
    int? rating,
    double? pairingProb,
    int? likelyRound,
    bool? prepared,
  }) => TournamentEntry(
    personId: personId,
    rating: rating ?? this.rating,
    pairingProb: pairingProb ?? this.pairingProb,
    likelyRound: likelyRound ?? this.likelyRound,
    prepared: prepared ?? this.prepared,
  );
}

class Tournament {
  /// File name stem, minted from the name at creation and never changed by a
  /// rename, so nothing that points at a tournament has to move with it.
  final String id;
  final String name;

  /// `YYYY-MM-DD`, or null when the user never said.
  final String? date;
  final int? rounds;
  final List<TournamentEntry> entries;
  final String? studyPath;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Tournament({
    required this.id,
    required this.name,
    this.date,
    this.rounds,
    this.entries = const [],
    this.studyPath,
    required this.createdAt,
    required this.updatedAt,
  });

  int get preparedCount => entries.where((e) => e.prepared).length;

  /// Index of the entry for [personId], or -1.
  int indexOf(String personId) =>
      entries.indexWhere((e) => e.personId == personId);

  bool contains(String personId) => indexOf(personId) >= 0;

  /// The date as `2026-04-12` and the round count as one line, or ''.
  String get whenLine => [
    ?date,
    if (rounds != null) '$rounds round${rounds == 1 ? '' : 's'}',
  ].join(' · ');

  Map<String, dynamic> toJson() => {
    'format': kTournamentFormat,
    'id': id,
    'name': name,
    'date': ?date,
    'rounds': ?rounds,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'entries': [for (final e in entries) e.toJson()],
    if (studyPath != null) 'study': studyPath,
  };

  factory Tournament.fromJson(Map<String, dynamic> json, {String? fallbackId}) {
    final now = DateTime.now();
    final format = json['format'];
    if (format is String && format.isNotEmpty && format != kTournamentFormat) {
      throw FormatException('Unknown tournament format "$format".');
    }
    return Tournament(
      id: json['id'] as String? ?? fallbackId ?? newTournamentId(''),
      name: (json['name'] as String? ?? '').trim(),
      studyPath: json['study'] as String?,
      date: (json['date'] as String?)?.trim(),
      rounds: (json['rounds'] as num?)?.toInt(),
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ?? now,
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ?? now,
      entries: [
        for (final e in (json['entries'] as List?) ?? const [])
          if (e is Map) TournamentEntry.fromJson(e.cast<String, dynamic>()),
      ],
    );
  }

  Tournament copyWith({
    String? name,
    String? date,
    bool clearDate = false,
    int? rounds,
    bool clearRounds = false,
    List<TournamentEntry>? entries,
    String? studyPath,
    DateTime? updatedAt,
  }) => Tournament(
    id: id,
    name: name?.trim() ?? this.name,
    date: clearDate ? null : (date ?? this.date),
    rounds: clearRounds ? null : (rounds ?? this.rounds),
    entries: entries ?? this.entries,
    studyPath: studyPath ?? this.studyPath,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  /// This tournament with [entry] added, or replaced if the person is
  /// already in the field.
  Tournament withEntry(TournamentEntry entry) {
    final i = indexOf(entry.personId);
    final next = [...entries];
    if (i >= 0) {
      next[i] = entry;
    } else {
      next.add(entry);
    }
    return copyWith(entries: next);
  }

  Tournament withoutPerson(String personId) => copyWith(
    entries: [
      for (final e in entries)
        if (e.personId != personId) e,
    ],
  );

  @override
  String toString() => 'Tournament($id, $name, ${entries.length} entries)';
}

const kTournamentFormat = 'chess-auto-prep/tournament@1';

/// A file-name-safe id from a tournament name: `Spring Open 2026` →
/// `spring-open-2026`. Empty names get a timestamp so the file still has a
/// name.
String newTournamentId(String name) {
  final slug = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.isNotEmpty) return slug;
  return 'tournament-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
}
