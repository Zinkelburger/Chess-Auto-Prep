/// The Week in Chess (theweekinchess.com) as a game source.
///
/// TWIC publishes one zip per weekly issue at
/// `https://theweekinchess.com/zips/twic{N}g.zip`; PGN issues exist from
/// issue 920 (September 2012) onward, a new one every Monday.  There is no
/// API and no bundle, so "download all" is a walk over issue numbers.  The
/// games are free for personal use.
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

import '../../utils/file_text_reader.dart';

/// First issue with a PGN zip.
const int kTwicFirstPgnIssue = 920;

/// A reference point for the weekly cadence: issue 1658 was published on
/// 2026-08-17.  Used only to *estimate* the current issue; the sync probes
/// the real upper bound.
const int kTwicReferenceIssue = 1658;
final DateTime kTwicReferenceDate = DateTime.utc(2026, 8, 17);

const String kTwicZipBase = 'https://theweekinchess.com/zips/';

/// Issue number expected on [date] given the weekly cadence (may overshoot
/// by one around skipped weeks; callers probe).
int twicIssueEstimateFor(DateTime date) {
  final weeks = date.toUtc().difference(kTwicReferenceDate).inDays ~/ 7;
  return kTwicReferenceIssue + weeks;
}

/// The issue roughly [years] years before [now] — the default starting
/// point for a first download.
int twicIssueYearsBack(int years, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final est = twicIssueEstimateFor(n) - years * 52;
  return est < kTwicFirstPgnIssue ? kTwicFirstPgnIssue : est;
}

Uri twicZipUri(int issue) => Uri.parse('${kTwicZipBase}twic${issue}g.zip');

class TwicDownloadException implements Exception {
  final int issue;
  final String message;
  const TwicDownloadException(this.issue, this.message);
  @override
  String toString() => 'TWIC $issue: $message';
}

class TwicClient {
  final http.Client _http;
  static const _userAgent = 'ChessAutoPrep (+https://github.com/)';

  TwicClient({http.Client? httpClient}) : _http = httpClient ?? http.Client();

  void close() => _http.close();

  /// Whether issue [issue] is published (HEAD on its zip).
  Future<bool> exists(int issue) async {
    final r = await _http.head(
      twicZipUri(issue),
      headers: {'User-Agent': _userAgent},
    );
    return r.statusCode == 200;
  }

  /// Highest published issue near [from]: walks up from the first hit until
  /// two consecutive misses (tolerating one skipped number), or — when
  /// [from] itself is not published — walks down up to [maxBacktrack]
  /// issues to find the newest one that is.  Null when nothing answers,
  /// which means the site is unreachable rather than "no issues".
  Future<int?> latestIssue({required int from, int maxBacktrack = 8}) async {
    var n = from;
    if (!await exists(n)) {
      for (var back = 1; back <= maxBacktrack; back++) {
        if (n - back < kTwicFirstPgnIssue) return null;
        if (await exists(n - back)) return n - back;
      }
      return null;
    }
    var last = n;
    var misses = 0;
    n++;
    while (misses < 2) {
      if (await exists(n)) {
        last = n;
        misses = 0;
      } else {
        misses++;
      }
      n++;
    }
    return last;
  }

  /// Download and unzip one issue; returns the PGN text (all `.pgn` members
  /// concatenated — there is normally exactly one).
  Future<String> fetchIssuePgn(int issue) async {
    final r = await _http.get(
      twicZipUri(issue),
      headers: {'User-Agent': _userAgent},
    );
    if (r.statusCode == 404) {
      throw TwicDownloadException(issue, 'not published');
    }
    if (r.statusCode != 200) {
      throw TwicDownloadException(issue, 'HTTP ${r.statusCode}');
    }
    return unzipPgn(r.bodyBytes, issue: issue);
  }

  /// Extract the PGN text from a TWIC zip body.
  static String unzipPgn(Uint8List zipBytes, {required int issue}) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes);
    } catch (e) {
      throw TwicDownloadException(issue, 'bad zip: $e');
    }
    final buf = StringBuffer();
    for (final f in archive.files) {
      if (!f.isFile || !f.name.toLowerCase().endsWith('.pgn')) continue;
      buf.write(decodeTextBytes(f.content));
      buf.write('\n\n');
    }
    if (buf.isEmpty) {
      throw TwicDownloadException(issue, 'zip has no .pgn member');
    }
    return buf.toString();
  }
}
