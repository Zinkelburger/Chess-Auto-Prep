/// Where the Lichess cloud evaluations come from, and how big they are today.
///
/// Lichess publishes one file — no snapshot directory, no manifest — and
/// refreshes it in place every few weeks, so "which version do I have" is the
/// file's `Last-Modified`.  The position count and publication date are only
/// stated on the download page, so the probe reads both: a `HEAD` for the
/// size and stamp, and the page for the numbers worth showing a person.
library;

import 'package:http/http.dart' as http;

const String kLichessEvalUrl =
    'https://database.lichess.org/lichess_db_eval.jsonl.zst';

const String kLichessDatabasePageUrl = 'https://database.lichess.org/#evals';

const String _kIndexUrl = 'https://database.lichess.org/';

/// What the file looked like on 2 September 2026, used when the probe cannot
/// reach the site so the settings panel can still state honest magnitudes.
const int kLichessEvalFallbackBytes = 21681515630;
const int kLichessEvalFallbackPositions = 394669566;
const String kLichessEvalFallbackUpdated = '2026-08-02';

/// The published file as it is right now.
class LichessEvalSourceInfo {
  const LichessEvalSourceInfo({
    required this.bytes,
    required this.lastModified,
    required this.positions,
    required this.updatedOn,
    this.probed = true,
  });

  /// Size of the `.zst` download.
  final int bytes;

  /// The `Last-Modified` header verbatim — the identity of this publication,
  /// carried into the store's manifest so a refresh is detectable.
  final String? lastModified;

  /// Positions the page advertises.
  final int positions;

  /// Publication date the page states.
  final DateTime? updatedOn;

  /// False when this is the built-in fallback rather than a live answer.
  final bool probed;

  /// The store this file expands to: one 15-byte record per position.
  int get storeBytes => positions * 15 + 32;

  static const LichessEvalSourceInfo fallback = LichessEvalSourceInfo(
    bytes: kLichessEvalFallbackBytes,
    lastModified: null,
    positions: kLichessEvalFallbackPositions,
    updatedOn: null,
    probed: false,
  );
}

/// `394,669,566` out of `<strong>394,669,566</strong> chess positions`.
int? parseLichessPositionCount(String html) {
  final match = RegExp(
    r'<strong>([\d,]+)</strong>\s*chess positions',
  ).firstMatch(html);
  if (match == null) return null;
  return int.tryParse(match.group(1)!.replaceAll(',', ''));
}

/// The date from `This file was last updated on 2026-08-02.`
///
/// The page states it once per section, and the evals section is the only one
/// that also names a position count, so the two are read from the same block.
DateTime? parseLichessUpdatedOn(String html) {
  final evals = html.indexOf('id="evals"');
  final from = evals < 0 ? 0 : evals;
  final match = RegExp(
    r'last updated on (\d{4})-(\d{2})-(\d{2})',
  ).firstMatch(html.substring(from));
  if (match == null) return null;
  return DateTime(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
}

class LichessEvalSource {
  LichessEvalSource({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  /// Size, stamp and advertised counts.
  ///
  /// Never throws: an unreachable site yields [LichessEvalSourceInfo.fallback]
  /// so the panel can still describe the download instead of showing an error
  /// where a size belongs.
  Future<LichessEvalSourceInfo> probe() async {
    int? bytes;
    String? lastModified;
    try {
      final head = await _http.head(Uri.parse(kLichessEvalUrl));
      if (head.statusCode == 200) {
        bytes = int.tryParse(head.headers['content-length'] ?? '');
        lastModified = head.headers['last-modified'];
      }
    } catch (_) {
      // Fall through to the page, then to the fallback.
    }

    int? positions;
    DateTime? updatedOn;
    try {
      final page = await _http.get(Uri.parse(_kIndexUrl));
      if (page.statusCode == 200) {
        positions = parseLichessPositionCount(page.body);
        updatedOn = parseLichessUpdatedOn(page.body);
      }
    } catch (_) {
      // Same.
    }

    if (bytes == null && positions == null) {
      return LichessEvalSourceInfo.fallback;
    }
    return LichessEvalSourceInfo(
      bytes: bytes ?? kLichessEvalFallbackBytes,
      lastModified: lastModified,
      positions: positions ?? kLichessEvalFallbackPositions,
      updatedOn: updatedOn,
    );
  }

  void dispose() => _http.close();
}
