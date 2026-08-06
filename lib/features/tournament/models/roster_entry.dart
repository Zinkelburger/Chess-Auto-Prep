/// The field for one event: who entered, how strong they are, and what we
/// know about their online accounts.
library;

import 'player_identity.dart';

/// One entrant on a tournament entry list.
class RosterEntry {
  /// Stable key used by the pairer, the simulator, and the MCP wire format.
  /// The USCF ID when we have one, otherwise a slug of the name.
  final String id;

  /// Name exactly as the entry list published it.
  final String name;

  final String? uscfId;

  /// Rating used for pairing and for the result model. Null ratings are
  /// treated as unrated and seeded at the bottom.
  final int? rating;

  /// Section, when the event has more than one. Players only face entrants in
  /// their own section.
  final String? section;

  /// Title as published on the entry list (GM/IM/FM/…). Distinct from the
  /// title on [identity], which comes from the chess.com roster.
  final String? title;

  /// Resolved online account(s), once identity resolution has run.
  final PlayerIdentity? identity;

  /// True for the single entrant who is the user. Prep is computed relative
  /// to this player.
  final bool isMe;

  /// Probability this entrant actually plays. Late entries and maybes get a
  /// value below 1.0; the simulator weights them accordingly rather than
  /// forcing a yes/no call the organizer has not made yet.
  final double attendanceProb;

  /// Rounds this player has requested a half-point bye for.
  final Set<int> halfPointByeRounds;

  /// Withdrawn — excluded from pairing entirely.
  final bool withdrawn;

  const RosterEntry({
    required this.id,
    required this.name,
    this.uscfId,
    this.rating,
    this.section,
    this.title,
    this.identity,
    this.isMe = false,
    this.attendanceProb = 1.0,
    this.halfPointByeRounds = const {},
    this.withdrawn = false,
  });

  /// Rating for seeding purposes; unrated players sort to the bottom.
  int get seedRating => rating ?? 0;

  bool get isRated => rating != null;

  /// The account prep should be built from, preferring chess.com (which the
  /// bundled directory resolves) over lichess.
  String? get preferredUsername =>
      identity?.chesscomUsername ?? identity?.lichessUsername;

  /// Platform key matching [AnalysisGamesService]'s storage convention.
  String? get preferredPlatform {
    final id = identity;
    if (id == null) return null;
    if (id.chesscomUsername != null && id.chesscomUsername!.isNotEmpty) {
      return 'chess.com';
    }
    if (id.lichessUsername != null && id.lichessUsername!.isNotEmpty) {
      return 'lichess';
    }
    return null;
  }

  RosterEntry copyWith({
    String? id,
    String? name,
    String? uscfId,
    int? rating,
    String? section,
    String? title,
    PlayerIdentity? identity,
    bool? isMe,
    double? attendanceProb,
    Set<int>? halfPointByeRounds,
    bool? withdrawn,
  }) => RosterEntry(
    id: id ?? this.id,
    name: name ?? this.name,
    uscfId: uscfId ?? this.uscfId,
    rating: rating ?? this.rating,
    section: section ?? this.section,
    title: title ?? this.title,
    identity: identity ?? this.identity,
    isMe: isMe ?? this.isMe,
    attendanceProb: attendanceProb ?? this.attendanceProb,
    halfPointByeRounds: halfPointByeRounds ?? this.halfPointByeRounds,
    withdrawn: withdrawn ?? this.withdrawn,
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    if (uscfId != null) 'uscf_id': uscfId,
    if (rating != null) 'rating': rating,
    if (section != null) 'section': section,
    if (title != null) 'title': title,
    if (identity != null) 'identity': identity!.toMap(),
    if (isMe) 'is_me': true,
    if (attendanceProb != 1.0) 'attendance_prob': attendanceProb,
    if (halfPointByeRounds.isNotEmpty)
      'half_point_byes': halfPointByeRounds.toList()..sort(),
    if (withdrawn) 'withdrawn': true,
  };

  factory RosterEntry.fromMap(Map<String, dynamic> m) => RosterEntry(
    id: (m['id'] ?? m['uscf_id'] ?? m['name'] ?? '').toString(),
    name: (m['name'] ?? '').toString(),
    uscfId: m['uscf_id'] as String?,
    rating: (m['rating'] as num?)?.toInt(),
    section: m['section'] as String?,
    title: m['title'] as String?,
    identity: m['identity'] is Map
        ? PlayerIdentity.fromMap((m['identity'] as Map).cast<String, dynamic>())
        : null,
    isMe: m['is_me'] as bool? ?? false,
    attendanceProb: (m['attendance_prob'] as num?)?.toDouble() ?? 1.0,
    halfPointByeRounds:
        (m['half_point_byes'] as List?)
            ?.map((e) => (e as num).toInt())
            .toSet() ??
        const {},
    withdrawn: m['withdrawn'] as bool? ?? false,
  );
}

/// A pair of players who must never be paired against each other — family
/// members, club-mates the TD has agreed to keep apart, or a rematch the
/// organizer wants to avoid.
///
/// Structurally identical to the no-repeat rule the pairer already enforces,
/// so honoring these costs nothing once the pairer exists.
class PairingConstraint {
  final String playerIdA;
  final String playerIdB;
  final String? reason;

  const PairingConstraint(this.playerIdA, this.playerIdB, {this.reason});

  bool involves(String a, String b) =>
      (playerIdA == a && playerIdB == b) || (playerIdA == b && playerIdB == a);

  Map<String, dynamic> toMap() => {
    'a': playerIdA,
    'b': playerIdB,
    if (reason != null) 'reason': reason,
  };

  factory PairingConstraint.fromMap(Map<String, dynamic> m) =>
      PairingConstraint(
        (m['a'] ?? '').toString(),
        (m['b'] ?? '').toString(),
        reason: m['reason'] as String?,
      );
}

/// A full entry list plus the event's shape.
class Roster {
  final String eventName;
  final List<RosterEntry> entries;
  final List<PairingConstraint> constraints;

  /// Number of rounds. Drives how far the simulator projects.
  final int rounds;

  /// Whether the organizer uses accelerated pairings. Usually announced in the
  /// event's TLA; we do not try to detect it.
  final bool accelerated;

  const Roster({
    this.eventName = '',
    this.entries = const [],
    this.constraints = const [],
    this.rounds = 5,
    this.accelerated = false,
  });

  RosterEntry? get me {
    for (final e in entries) {
      if (e.isMe) return e;
    }
    return null;
  }

  /// Entrants actually in the pairing pool.
  List<RosterEntry> get active =>
      entries.where((e) => !e.withdrawn).toList(growable: false);

  /// Distinct section names, in first-seen order. Empty when the event is
  /// single-section.
  List<String> get sections {
    final seen = <String>[];
    for (final e in entries) {
      final s = e.section;
      if (s != null && s.isNotEmpty && !seen.contains(s)) seen.add(s);
    }
    return seen;
  }

  /// Entrants in the same section as [entry] (all of them when unsectioned).
  List<RosterEntry> sectionOf(RosterEntry entry) {
    if (entry.section == null || entry.section!.isEmpty) return active;
    return active.where((e) => e.section == entry.section).toList();
  }

  int get resolvedCount =>
      entries.where((e) => e.identity?.hasAccount ?? false).length;

  Roster copyWith({
    String? eventName,
    List<RosterEntry>? entries,
    List<PairingConstraint>? constraints,
    int? rounds,
    bool? accelerated,
  }) => Roster(
    eventName: eventName ?? this.eventName,
    entries: entries ?? this.entries,
    constraints: constraints ?? this.constraints,
    rounds: rounds ?? this.rounds,
    accelerated: accelerated ?? this.accelerated,
  );

  /// Replace one entry by id, returning a new roster.
  Roster withEntry(RosterEntry updated) => copyWith(
    entries: entries
        .map((e) => e.id == updated.id ? updated : e)
        .toList(growable: false),
  );

  Map<String, dynamic> toMap() => {
    'event_name': eventName,
    'rounds': rounds,
    'accelerated': accelerated,
    'entries': entries.map((e) => e.toMap()).toList(),
    if (constraints.isNotEmpty)
      'constraints': constraints.map((c) => c.toMap()).toList(),
  };

  factory Roster.fromMap(Map<String, dynamic> m) => Roster(
    eventName: (m['event_name'] ?? '').toString(),
    rounds: (m['rounds'] as num?)?.toInt() ?? 5,
    accelerated: m['accelerated'] as bool? ?? false,
    entries:
        (m['entries'] as List?)
            ?.map(
              (e) => RosterEntry.fromMap((e as Map).cast<String, dynamic>()),
            )
            .toList() ??
        const [],
    constraints:
        (m['constraints'] as List?)
            ?.map(
              (c) =>
                  PairingConstraint.fromMap((c as Map).cast<String, dynamic>()),
            )
            .toList() ??
        const [],
  );
}
