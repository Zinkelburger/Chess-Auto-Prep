/// Identity of a tournament entrant's online account(s), and how we know it.
///
/// An identity is never a bare string. Every resolved account carries the
/// method that produced it and a confidence, because the downstream prep
/// report has to be able to say "this line is speculative" when the match is
/// weak — and because a wrong match means preparing against the wrong person.
library;

/// How an online account was tied to a real-world entrant.
///
/// Ordered strongest-first. The top two are *structural* — they come from
/// records the player created by entering an event — while the lower ones are
/// inference and should stay human-confirmable.
enum IdentitySource {
  /// Matched through USCF-rated events hosted on chess.com, by round-by-round
  /// opponent-graph isomorphism between the USCF and chess.com crosstables.
  /// The player linked the accounts themselves by entering; we only read it.
  uscfOnlineEvent,

  /// The account states the USCF ID or real name on its public profile.
  selfDeclared,

  /// Matched against the chess.com titled-player roster by name.
  titledRoster,

  /// Proposed by an agent (web search, profile reading). Never auto-trusted.
  agentProposed,

  /// Typed in by the user.
  manual,
}

extension IdentitySourceLabel on IdentitySource {
  String get label => switch (this) {
    IdentitySource.uscfOnlineEvent => 'USCF online event',
    IdentitySource.selfDeclared => 'Self-declared on profile',
    IdentitySource.titledRoster => 'Titled roster',
    IdentitySource.agentProposed => 'Agent proposed',
    IdentitySource.manual => 'Entered manually',
  };

  /// Whether a match from this source can be used without the user confirming
  /// it. Inference-based sources always need a human in the loop.
  bool get isSelfEvidencing =>
      this == IdentitySource.uscfOnlineEvent ||
      this == IdentitySource.selfDeclared ||
      this == IdentitySource.manual;

  String get wireName => switch (this) {
    IdentitySource.uscfOnlineEvent => 'uscf_online_event',
    IdentitySource.selfDeclared => 'self_declared',
    IdentitySource.titledRoster => 'titled_roster',
    IdentitySource.agentProposed => 'agent_proposed',
    IdentitySource.manual => 'manual',
  };

  static IdentitySource fromWire(String? s) => switch (s) {
    'uscf_online_event' => IdentitySource.uscfOnlineEvent,
    'self_declared' => IdentitySource.selfDeclared,
    'titled_roster' => IdentitySource.titledRoster,
    'manual' => IdentitySource.manual,
    _ => IdentitySource.agentProposed,
  };
}

/// How sure we are of a linkage.
enum IdentityConfidence { exact, high, medium, low, ambiguous }

extension IdentityConfidenceLabel on IdentityConfidence {
  String get label => switch (this) {
    IdentityConfidence.exact => 'Exact',
    IdentityConfidence.high => 'High',
    IdentityConfidence.medium => 'Medium',
    IdentityConfidence.low => 'Low',
    IdentityConfidence.ambiguous => 'Ambiguous',
  };

  String get wireName => name;

  /// Whether prep built on this match should be presented without a caveat.
  bool get isTrustworthy =>
      this == IdentityConfidence.exact || this == IdentityConfidence.high;

  static IdentityConfidence fromWire(String? s) => switch (s) {
    'exact' => IdentityConfidence.exact,
    'high' => IdentityConfidence.high,
    'medium' => IdentityConfidence.medium,
    'low' => IdentityConfidence.low,
    _ => IdentityConfidence.ambiguous,
  };
}

/// A resolved (or proposed) set of online accounts for one entrant.
class PlayerIdentity {
  final String? chesscomUsername;
  final String? lichessUsername;
  final IdentityConfidence confidence;
  final IdentitySource source;

  /// Free-text description of *why* this match holds — the event it came from,
  /// the profile line that declared it, the search result an agent read.
  /// Shown verbatim in the UI so a weak match is visibly weak.
  final String? evidence;

  /// Other plausible accounts, when the match was not unique. Non-empty here
  /// is the signal to ask the user rather than pick.
  final List<String> alternates;

  /// Chess.com title (GM/IM/FM/NM/CM) if the account is on the titled roster.
  final String? title;

  const PlayerIdentity({
    this.chesscomUsername,
    this.lichessUsername,
    this.confidence = IdentityConfidence.ambiguous,
    this.source = IdentitySource.agentProposed,
    this.evidence,
    this.alternates = const [],
    this.title,
  });

  bool get hasAccount =>
      (chesscomUsername != null && chesscomUsername!.isNotEmpty) ||
      (lichessUsername != null && lichessUsername!.isNotEmpty);

  /// Whether this can drive prep without asking the user first.
  bool get isActionable =>
      hasAccount &&
      alternates.isEmpty &&
      confidence.isTrustworthy &&
      source.isSelfEvidencing;

  PlayerIdentity copyWith({
    String? chesscomUsername,
    String? lichessUsername,
    IdentityConfidence? confidence,
    IdentitySource? source,
    String? evidence,
    List<String>? alternates,
    String? title,
  }) => PlayerIdentity(
    chesscomUsername: chesscomUsername ?? this.chesscomUsername,
    lichessUsername: lichessUsername ?? this.lichessUsername,
    confidence: confidence ?? this.confidence,
    source: source ?? this.source,
    evidence: evidence ?? this.evidence,
    alternates: alternates ?? this.alternates,
    title: title ?? this.title,
  );

  Map<String, dynamic> toMap() => {
    if (chesscomUsername != null) 'chesscom_username': chesscomUsername,
    if (lichessUsername != null) 'lichess_username': lichessUsername,
    'confidence': confidence.wireName,
    'source': source.wireName,
    if (evidence != null) 'evidence': evidence,
    if (alternates.isNotEmpty) 'alternates': alternates,
    if (title != null) 'title': title,
  };

  factory PlayerIdentity.fromMap(Map<String, dynamic> m) => PlayerIdentity(
    chesscomUsername: m['chesscom_username'] as String?,
    lichessUsername: m['lichess_username'] as String?,
    confidence: IdentityConfidenceLabel.fromWire(m['confidence'] as String?),
    source: IdentitySourceLabel.fromWire(m['source'] as String?),
    evidence: m['evidence'] as String?,
    alternates:
        (m['alternates'] as List?)?.map((e) => e.toString()).toList() ??
        const [],
    title: m['title'] as String?,
  );
}
