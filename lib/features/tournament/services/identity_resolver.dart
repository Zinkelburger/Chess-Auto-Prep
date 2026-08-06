/// Resolve entry-list names to online accounts using the bundled directory.
///
/// This is the automatic tier: USCF IDs and names matched against the
/// opponent-graph mapping shipped in `assets/data/uscf_chesscom_map.json`.
/// It is deliberately conservative — an ambiguous name yields an identity
/// carrying [PlayerIdentity.alternates] rather than a pick, and nothing here
/// ever overwrites an identity the user asserted themselves.
///
/// Entrants this cannot resolve are the input to the agent-assisted tier over
/// the MCP bridge, which can search the web and read profiles. That tier
/// proposes; it does not decide.
library;

import '../models/player_identity.dart';
import '../models/roster_entry.dart';
import 'player_directory.dart';

/// Outcome of resolving one roster.
class ResolutionSummary {
  final Roster roster;

  /// Entrants now carrying a usable account.
  final int resolved;

  /// Entrants whose name matched several directory rows.
  final int ambiguous;

  /// Entrants the directory knows nothing about.
  final int unresolved;

  const ResolutionSummary({
    required this.roster,
    required this.resolved,
    required this.ambiguous,
    required this.unresolved,
  });

  int get total => resolved + ambiguous + unresolved;

  double get hitRate => total == 0 ? 0 : resolved / total;

  /// Entrants an agent should try to resolve, as plain data for the MCP tool.
  List<Map<String, dynamic>> get unresolvedEntries => roster.entries
      .where((e) => !e.isMe && !(e.identity?.isActionable ?? false))
      .map(
        (e) => {
          'id': e.id,
          'name': e.name,
          if (e.uscfId != null) 'uscf_id': e.uscfId,
          if (e.rating != null) 'rating': e.rating,
          if (e.title != null) 'title': e.title,
          if (e.identity?.alternates.isNotEmpty ?? false)
            'candidates': e.identity!.alternates,
        },
      )
      .toList();

  Map<String, dynamic> toMap() => {
    'resolved': resolved,
    'ambiguous': ambiguous,
    'unresolved': unresolved,
    'hit_rate': hitRate,
    'roster': roster.toMap(),
  };
}

class IdentityResolver {
  /// Fill in identities for every entrant the directory can place.
  ///
  /// Identities already marked [IdentitySource.manual] are left untouched:
  /// the user's own assertion outranks a lookup.
  static ResolutionSummary resolveRoster(
    Roster roster, {
    PlayerDirectory? directory,
  }) {
    final dir = directory ?? PlayerDirectory.instance;

    var resolved = 0;
    var ambiguous = 0;
    var unresolved = 0;

    final entries = roster.entries.map((entry) {
      if (entry.identity?.source == IdentitySource.manual &&
          entry.identity!.hasAccount) {
        resolved++;
        return entry;
      }

      final found = dir.resolve(uscfId: entry.uscfId, name: entry.name);
      if (found == null) {
        unresolved++;
        return entry;
      }

      // Decorate with a title from the chess.com roster when we have one.
      final username = found.chesscomUsername;
      final identity = username == null
          ? found
          : found.copyWith(title: found.title ?? dir.titleFor(username));

      if (identity.hasAccount) {
        resolved++;
      } else {
        ambiguous++;
      }
      return entry.copyWith(identity: identity);
    }).toList();

    return ResolutionSummary(
      roster: roster.copyWith(entries: entries),
      resolved: resolved,
      ambiguous: ambiguous,
      unresolved: unresolved,
    );
  }

  /// Attach an account an agent proposed.
  ///
  /// Agent proposals never arrive as [IdentitySource.manual] and never claim
  /// exact confidence, so [PlayerIdentity.isActionable] stays false until a
  /// human confirms — which is what keeps a hallucinated username from
  /// silently becoming tournament prep.
  static Roster applyProposal(
    Roster roster, {
    required String playerId,
    String? chesscomUsername,
    String? lichessUsername,
    required String evidence,
    IdentityConfidence confidence = IdentityConfidence.medium,
    List<String> alternates = const [],
  }) {
    final entry = roster.entries.where((e) => e.id == playerId).firstOrNull;
    if (entry == null) return roster;

    return roster.withEntry(
      entry.copyWith(
        identity: PlayerIdentity(
          chesscomUsername: chesscomUsername,
          lichessUsername: lichessUsername,
          confidence: confidence,
          source: IdentitySource.agentProposed,
          evidence: evidence,
          alternates: alternates,
        ),
      ),
    );
  }

  /// Promote a proposal to a confirmed, usable identity. This is the only
  /// path from "an agent thinks so" to "prep runs against it".
  static Roster confirm(
    Roster roster, {
    required String playerId,
    String? chesscomUsername,
    String? lichessUsername,
  }) {
    final entry = roster.entries.where((e) => e.id == playerId).firstOrNull;
    if (entry == null) return roster;

    final existing = entry.identity;
    return roster.withEntry(
      entry.copyWith(
        identity: PlayerIdentity(
          chesscomUsername: chesscomUsername ?? existing?.chesscomUsername,
          lichessUsername: lichessUsername ?? existing?.lichessUsername,
          confidence: IdentityConfidence.exact,
          source: IdentitySource.manual,
          evidence: existing?.evidence == null
              ? 'Confirmed by the user'
              : 'Confirmed by the user — ${existing!.evidence}',
          title: existing?.title,
        ),
      ),
    );
  }
}
