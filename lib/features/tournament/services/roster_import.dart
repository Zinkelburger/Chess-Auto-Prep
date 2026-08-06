/// Parse a tournament entry list into a [Roster].
///
/// Entry lists arrive in whatever shape the organizer felt like publishing:
/// a CSV export from WinTD/SwissSys, a copy-paste out of an HTML table, or a
/// column-aligned text blob. Both paths are handled, and anything the parser
/// had to guess at is reported as a warning rather than silently assumed —
/// a misread rating shifts the seeding, which shifts every simulated pairing.
library;

import 'package:csv/csv.dart';

import '../models/player_identity.dart';
import '../models/roster_entry.dart';

/// Recognized header spellings, normalized to lowercase with punctuation and
/// spaces removed before matching.
const _nameAliases = {
  'name',
  'player',
  'playername',
  // "Player's Name" — the spelling US Chess event pages use.
  'playersname',
  'fullname',
  'participant',
  'entrant',
};
const _uscfAliases = {
  'uscf',
  'uscfid',
  'id',
  'memberid',
  'uscfno',
  'uscfnumber',
  'member',
};
const _ratingAliases = {
  'rating',
  'elo',
  'uscfrating',
  'rtg',
  'pre',
  'prerating',
  'regrating',
  'rating1',
};
const _sectionAliases = {'section', 'sect', 'sec', 'division'};
const _titleAliases = {'title', 'ttl'};
const _chesscomAliases = {'chesscom', 'chesscomusername', 'chesscomhandle'};
const _lichessAliases = {'lichess', 'lichessusername', 'lichesshandle'};

/// Provenance columns, written by [PrepExporter.rosterToCsv]. Reading them
/// back is what stops an export/import round trip from laundering an
/// unconfirmed agent guess into a trusted identity.
const _confidenceAliases = {'confidence'};
const _sourceAliases = {'source'};
const _evidenceAliases = {'evidence'};

/// Titles that may appear as a bare token in front of a name.
const _titleTokens = {
  'GM',
  'IM',
  'FM',
  'CM',
  'NM',
  'WGM',
  'WIM',
  'WFM',
  'WCM',
  'LM',
};

final _uscfIdPattern = RegExp(r'^\d{7,9}$');
// `1850`, `1850P12` (provisional), `1850/12`, `1850*`.
final _ratingPattern = RegExp(r'^(\d{3,4})\s*(?:[Pp]\d+|/\d+|\*)?$');

/// Bracketed annotations that trail a rating or an ID on US Chess pages:
/// `1900 [EQ]` (foreign rating converted to a US Chess equivalent),
/// `30992060 [USA]` (FIDE federation).
final _bracketSuffix = RegExp(r'\s*\[[^\]]*\]\s*');

/// `(Withdrawn)` in a name column — the organizer's own withdrawal marker.
final _withdrawnMarker = RegExp(r'\(\s*withdrawn\s*\)', caseSensitive: false);

/// A parenthesised title in a name column: `Tereshchenko, Eliza (WCM)`.
final _titleParen = RegExp(
  r'\(\s*(GM|IM|FM|CM|NM|WGM|WIM|WFM|WCM|LM)\s*\)',
  caseSensitive: false,
);

/// Ratings published as text rather than a number.
const _unratedWords = {'unr', 'unrated', 'none', 'nr', 'n/a'};
final _intPattern = RegExp(r'^\d+$');
final _columnSplit = RegExp(r'\t|\s{2,}');
final _slugStrip = RegExp(r'[^a-z0-9]+');

class RosterImportResult {
  final Roster roster;

  /// Everything the parser guessed at or dropped. Surfaced in the UI and in
  /// the MCP tool result so nothing is quietly wrong.
  final List<String> warnings;

  /// `csv` or `text` — which path handled the input.
  final String format;

  const RosterImportResult({
    required this.roster,
    this.warnings = const [],
    required this.format,
  });

  Map<String, dynamic> toMap() => {
    'format': format,
    'roster': roster.toMap(),
    'warnings': warnings,
    'entry_count': roster.entries.length,
  };
}

class RosterImporter {
  /// Parse [text] as an entry list.
  ///
  /// Tries CSV first (a header row with a recognizable name column), then
  /// falls back to column-aligned or whitespace-separated text.
  static RosterImportResult parse(
    String text, {
    String eventName = '',
    int rounds = 5,
    bool accelerated = false,
    String? myName,
    String? myUscfId,
  }) {
    final warnings = <String>[];
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return RosterImportResult(
        roster: Roster(eventName: eventName, rounds: rounds),
        warnings: const ['Entry list was empty.'],
        format: 'text',
      );
    }

    final csvEntries = _tryParseCsv(trimmed, warnings);
    final entries = csvEntries ?? _parseFreeform(trimmed, warnings);
    final format = csvEntries != null ? 'csv' : 'text';

    final deduped = _assignIds(entries, warnings);
    final marked = _markSelf(deduped, myName, myUscfId, warnings);

    if (marked.isEmpty) {
      warnings.add('No entrants could be parsed from the input.');
    }

    return RosterImportResult(
      roster: Roster(
        eventName: eventName,
        entries: marked,
        rounds: rounds,
        accelerated: accelerated,
      ),
      warnings: warnings,
      format: format,
    );
  }

  // ── CSV ────────────────────────────────────────────────────────────────

  /// Returns null when the input does not look like a CSV with a usable
  /// header, so the caller can fall through to the freeform parser.
  static List<RosterEntry>? _tryParseCsv(String text, List<String> warnings) {
    late final List<List<dynamic>> rows;
    try {
      // autoDetect picks the delimiter, so a tab-separated paste out of a web
      // table parses through this path too.
      rows = Csv(
        dynamicTyping: false,
        skipEmptyLines: true,
      ).decode(text.replaceAll('\r\n', '\n'));
    } catch (_) {
      return null;
    }

    if (rows.length < 2) return null;

    final header = rows.first.map((c) => _normalizeHeader('$c')).toList();
    final nameCol = _findColumn(header, _nameAliases);
    if (nameCol < 0) return null;

    final uscfCol = _findColumn(header, _uscfAliases);
    final ratingCol = _findColumn(header, _ratingAliases);
    final sectionCol = _findColumn(header, _sectionAliases);
    final titleCol = _findColumn(header, _titleAliases);
    final chesscomCol = _findColumn(header, _chesscomAliases);
    final lichessCol = _findColumn(header, _lichessAliases);
    final confidenceCol = _findColumn(header, _confidenceAliases);
    final sourceCol = _findColumn(header, _sourceAliases);
    final evidenceCol = _findColumn(header, _evidenceAliases);

    if (ratingCol < 0) {
      warnings.add(
        'No rating column found — every entrant will be treated as unrated, '
        'which makes seeding and pairing simulation meaningless.',
      );
    }

    final entries = <RosterEntry>[];
    for (var i = 1; i < rows.length; i++) {
      final row = rows[i];
      String cell(int col) =>
          (col >= 0 && col < row.length) ? '${row[col]}'.trim() : '';

      final rawName = cell(nameCol);
      if (rawName.isEmpty) continue;
      final parsedName = _parseNameCell(rawName);

      final ratingRaw = cell(ratingCol);
      final rating = _parseRating(ratingRaw);
      if (rating == null && !_isUnratedMarker(ratingRaw)) {
        warnings.add('Row ${i + 1}: could not read rating "$ratingRaw".');
      }

      entries.add(
        RosterEntry(
          id: '',
          name: parsedName.name,
          uscfId: _cleanUscfId(cell(uscfCol)),
          rating: rating,
          section: _blankToNull(cell(sectionCol)),
          title: _blankToNull(cell(titleCol).toUpperCase()) ?? parsedName.title,
          withdrawn: parsedName.withdrawn,
          identity: _identityFromColumns(
            cell(chesscomCol),
            cell(lichessCol),
            cell(confidenceCol),
            cell(sourceCol),
            cell(evidenceCol),
          ),
        ),
      );
    }

    return entries.isEmpty ? null : entries;
  }

  // ── Freeform text ──────────────────────────────────────────────────────

  static List<RosterEntry> _parseFreeform(String text, List<String> warnings) {
    final entries = <RosterEntry>[];

    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      // Prefer column boundaries (tab or 2+ spaces) so "Smith, John" survives
      // as one field; fall back to single spaces for compact lists.
      var tokens = line
          .split(_columnSplit)
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList();
      if (tokens.length < 2) {
        tokens = line.split(' ').where((t) => t.isNotEmpty).toList();
      }
      if (tokens.isEmpty) continue;

      // Drop a leading pair/seed number ("1", "12.").
      if (tokens.length > 2) {
        final head = tokens.first.replaceAll('.', '');
        if (_intPattern.hasMatch(head) && head.length <= 3) {
          tokens = tokens.sublist(1);
        }
      }

      String? uscfId;
      int? rating;
      String? title;
      final nameTokens = <String>[];

      for (final token in tokens) {
        if (uscfId == null && _uscfIdPattern.hasMatch(token)) {
          uscfId = token;
          continue;
        }
        if (rating == null) {
          final parsed = _parseRating(token);
          if (parsed != null) {
            rating = parsed;
            continue;
          }
        }
        if (title == null && _titleTokens.contains(token.toUpperCase())) {
          title = token.toUpperCase();
          continue;
        }
        nameTokens.add(token);
      }

      final name = nameTokens.join(' ').trim();
      if (name.isEmpty) continue;
      // A "name" that is only digits means the line was a standings row or
      // some other table we misread.
      if (_intPattern.hasMatch(name.replaceAll(' ', ''))) continue;

      if (rating == null && uscfId == null) {
        warnings.add('Line "$line": no rating or USCF ID found.');
      }

      entries.add(
        RosterEntry(
          id: '',
          name: name,
          uscfId: uscfId,
          rating: rating,
          title: title,
        ),
      );
    }

    return entries;
  }

  // ── Shared helpers ─────────────────────────────────────────────────────

  /// Give every entry a stable, unique id: USCF ID when present, otherwise a
  /// name slug, suffixed on collision.
  static List<RosterEntry> _assignIds(
    List<RosterEntry> entries,
    List<String> warnings,
  ) {
    final used = <String>{};
    final out = <RosterEntry>[];

    for (final entry in entries) {
      var base = entry.uscfId?.trim();
      if (base == null || base.isEmpty) {
        base = entry.name.toLowerCase().replaceAll(_slugStrip, '-');
        if (base.isEmpty) base = 'player';
      }

      var id = base;
      var n = 2;
      while (!used.add(id)) {
        id = '$base-$n';
        n++;
      }
      if (n > 2 && entry.uscfId != null) {
        warnings.add(
          'Duplicate USCF ID ${entry.uscfId} for "${entry.name}" — '
          'kept both entrants under distinct ids.',
        );
      }

      out.add(entry.copyWith(id: id));
    }

    return out;
  }

  static List<RosterEntry> _markSelf(
    List<RosterEntry> entries,
    String? myName,
    String? myUscfId,
    List<String> warnings,
  ) {
    if ((myName == null || myName.trim().isEmpty) &&
        (myUscfId == null || myUscfId.trim().isEmpty)) {
      return entries;
    }

    final wantId = myUscfId?.trim();
    final wantName = myName?.trim().toLowerCase();
    var matched = false;

    final out = entries.map((e) {
      if (matched) return e;
      final byId =
          wantId != null && wantId.isNotEmpty && e.uscfId?.trim() == wantId;
      final byName =
          wantName != null &&
          wantName.isNotEmpty &&
          e.name.toLowerCase() == wantName;
      if (byId || byName) {
        matched = true;
        return e.copyWith(isMe: true);
      }
      return e;
    }).toList();

    if (!matched) {
      warnings.add(
        'You were not found on the entry list (looked for '
        '${wantId?.isNotEmpty == true ? 'USCF $wantId' : '"$myName"'}). '
        'Set yourself manually — pairing probabilities need a reference point.',
      );
    }

    return out;
  }

  static int _findColumn(List<String> header, Set<String> aliases) {
    for (var i = 0; i < header.length; i++) {
      if (aliases.contains(header[i])) return i;
    }
    return -1;
  }

  static String _normalizeHeader(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// A name cell split from the markers organizers embed in it.
  ///
  /// `Tereshchenko, Eliza (WCM) (Withdrawn)` is three facts in one column, and
  /// leaving them in the string would both corrupt the directory join and hide
  /// the withdrawal from the pairing simulator.
  static ({String name, String? title, bool withdrawn}) _parseNameCell(
    String raw,
  ) {
    final withdrawn = _withdrawnMarker.hasMatch(raw);
    final titleMatch = _titleParen.firstMatch(raw);

    final cleaned = raw
        .replaceAll(_withdrawnMarker, ' ')
        .replaceAll(_titleParen, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    return (
      name: cleaned,
      title: titleMatch?.group(1)?.toUpperCase(),
      withdrawn: withdrawn,
    );
  }

  static int? _parseRating(String raw) {
    // `1900 [EQ]` is a real rating with an annotation, not an unreadable cell.
    final cleaned = raw.replaceAll(_bracketSuffix, ' ').trim();
    if (cleaned.isEmpty) return null;
    if (_unratedWords.contains(cleaned.toLowerCase())) return null;

    final m = _ratingPattern.firstMatch(cleaned);
    if (m == null) return null;
    final value = int.tryParse(m.group(1)!);
    if (value == null || value < 100 || value > 3200) return null;
    return value;
  }

  /// True when [raw] is a deliberate "no rating" marker rather than a value we
  /// failed to read — the difference between a warning and a shrug.
  static bool _isUnratedMarker(String raw) {
    final cleaned = raw.replaceAll(_bracketSuffix, ' ').trim().toLowerCase();
    return cleaned.isEmpty || _unratedWords.contains(cleaned);
  }

  static String? _cleanUscfId(String raw) {
    final digits = raw
        .replaceAll(_bracketSuffix, ' ')
        .trim()
        .replaceAll(RegExp(r'[^0-9]'), '');
    return _uscfIdPattern.hasMatch(digits) ? digits : null;
  }

  static String? _blankToNull(String? s) =>
      (s == null || s.trim().isEmpty) ? null : s.trim();

  /// Build an identity from explicit username columns.
  ///
  /// A username the user typed into their own spreadsheet is asserted, not
  /// inferred, so with no provenance columns present it lands as
  /// [IdentitySource.manual] at exact confidence.
  ///
  /// But this importer also reads back what [PrepExporter.rosterToCsv] wrote,
  /// and that file can contain unconfirmed agent proposals. Defaulting those
  /// to manual/exact would let an export/import round trip launder a guess
  /// into a trusted identity and silently bypass the confirmation gate — so
  /// when the provenance columns are present they win.
  static PlayerIdentity? _identityFromColumns(
    String chesscom,
    String lichess,
    String confidence,
    String source,
    String evidence,
  ) {
    final cc = chesscom.trim();
    final li = lichess.trim();
    if (cc.isEmpty && li.isEmpty) return null;

    final hasProvenance =
        confidence.trim().isNotEmpty || source.trim().isNotEmpty;

    return PlayerIdentity(
      chesscomUsername: cc.isEmpty ? null : cc,
      lichessUsername: li.isEmpty ? null : li,
      confidence: hasProvenance
          ? IdentityConfidenceLabel.fromWire(confidence.trim())
          : IdentityConfidence.exact,
      source: hasProvenance
          ? IdentitySourceLabel.fromWire(source.trim())
          : IdentitySource.manual,
      evidence: evidence.trim().isNotEmpty
          ? evidence.trim()
          : 'Supplied on the imported entry list',
    );
  }
}
