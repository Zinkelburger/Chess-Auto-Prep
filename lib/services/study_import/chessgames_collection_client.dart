/// Reading a chessgames.com collection: the game ids on the collection page,
/// then one PGN per game.
///
/// Two very different requests hide behind that:
///
///   * **The collection page** is plain HTML behind an AWS WAF. A non-browser
///     request often gets a challenge page instead — tiny, no `gid=` links.
///     [extractCollectionGameIds] returning empty *is* that signal, and the
///     caller is expected to fall back to asking the user for the ids
///     ([parsePastedGameIds] takes either a pasted id list or the saved page
///     source).
///   * **`/njs/api/game/viewPGN/<gid>`** answers plain PGN and generally does
///     not need a browser session — but it bans fast callers. ~2–3 s apart
///     gets a 429 after 15–20 games; ~22 s apart sustains 60. Pacing is the
///     caller's job ([StudyImportController] owns the loop); this file only
///     classifies each response.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../chess_api_urls.dart';

/// Sent on every chessgames.com request. The API 403s obvious bots, and the
/// `Referer`/`Origin` pair is what the site's own front-end sends.
Map<String, String> _headers(String? refererGid) => {
  'User-Agent':
      'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/126.0.0.0 Safari/537.36',
  'Accept': 'text/plain,text/html,*/*',
  'Accept-Language': 'en-US,en;q=0.9',
  if (refererGid != null) 'Referer': chessgamesGameUrl(refererGid).toString(),
  'Origin': 'https://www.chessgames.com',
};

/// How a single `viewPGN` request turned out.
enum ChessgamesFetchStatus {
  /// Body was PGN — [ChessgamesFetch.pgn] is set.
  ok,

  /// 429/403, or an HTML "too many requests"/"maintenance" body. Back off and
  /// retry the same game.
  throttled,

  /// Anything else: a 404, a malformed body, a socket error. Skip the game.
  failed,
}

typedef ChessgamesFetch = ({ChessgamesFetchStatus status, String? pgn});

// ── Collection page ──────────────────────────────────────────────────────

/// Fetch the collection page HTML for [cid].
///
/// Returns the body whatever the status code — a WAF challenge is a 200 with
/// useless content, so the caller judges by whether ids came out of it.
/// Returns `null` only when the request could not be made at all.
Future<String?> fetchCollectionHtml(String cid, {http.Client? client}) async {
  final owned = client == null;
  final http_ = client ?? http.Client();
  try {
    final response = await http_
        .get(chessgamesCollectionUrl(cid), headers: _headers(null))
        .timeout(const Duration(seconds: 30));
    return const Utf8Decoder(allowMalformed: true).convert(response.bodyBytes);
  } catch (_) {
    return null;
  } finally {
    if (owned) http_.close();
  }
}

/// Every `gid=` linked from [html], in page order, de-duplicated.
///
/// Collection pages list each game twice (the board thumbnail and the move
/// list link), and page order is the order the collection's author chose — so
/// first-seen order is the order to import in.
List<String> extractCollectionGameIds(String html) {
  final ids = <String>[];
  final seen = <String>{};
  for (final match in RegExp(r'gid=(\d+)').allMatches(html)) {
    final id = match.group(1)!;
    if (seen.add(id)) ids.add(id);
  }
  return ids;
}

/// The collection's name, from the page `<title>`.
///
/// Returns `null` when the page is a WAF challenge or otherwise title-less.
String? extractCollectionTitle(String html) {
  final match = RegExp(
    r'<title>(.*?)</title>',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(html);
  if (match == null) return null;

  var title = _unescapeHtml(
    match.group(1)!,
  ).replaceAll(RegExp(r'\s+'), ' ').trim();
  // "Chess collection: Fischer's 60 Memorable Games" → drop the boilerplate.
  title = title.replaceFirst(
    RegExp(r'^chess\s+(game\s+)?collection\s*:\s*', caseSensitive: false),
    '',
  );
  title = title.replaceFirst(
    RegExp(r'\s*-\s*chessgames\.com\s*$', caseSensitive: false),
    '',
  );
  return title.isEmpty ? null : title;
}

/// Pull game ids out of whatever the user pasted when the collection page was
/// blocked: a whole saved page source, a list of URLs, or bare ids one per
/// line.
///
/// Bare numbers are only accepted when the text holds no `gid=` at all, so
/// pasting page HTML can't pick up unrelated digits.
List<String> parsePastedGameIds(String text) {
  final fromLinks = extractCollectionGameIds(text);
  if (fromLinks.isNotEmpty) return fromLinks;

  final ids = <String>[];
  final seen = <String>{};
  for (final match in RegExp(r'\b(\d{4,9})\b').allMatches(text)) {
    final id = match.group(1)!;
    if (seen.add(id)) ids.add(id);
  }
  return ids;
}

// ── Single game ──────────────────────────────────────────────────────────

/// Fetch one game's PGN.
///
/// Never throws: transport errors come back as [ChessgamesFetchStatus.failed]
/// so a long collection run is not derailed by one bad game.
Future<ChessgamesFetch> fetchGamePgn(String gid, {http.Client? client}) async {
  final owned = client == null;
  final http_ = client ?? http.Client();
  try {
    final response = await http_
        .get(chessgamesPgnUrl(gid), headers: _headers(gid))
        .timeout(const Duration(seconds: 30));
    return classifyPgnResponse(
      response.statusCode,
      const Utf8Decoder(allowMalformed: true).convert(response.bodyBytes),
    );
  } catch (_) {
    return (status: ChessgamesFetchStatus.failed, pgn: null);
  } finally {
    if (owned) http_.close();
  }
}

/// Decide what a `viewPGN` response means.
///
/// Split out from [fetchGamePgn] because the soft-ban cases are the ones worth
/// testing: chessgames.com answers a rate-limit with a *200 and an HTML page*
/// as often as with a 429.
ChessgamesFetch classifyPgnResponse(int statusCode, String body) {
  if (statusCode == 429 || statusCode == 403 || statusCode == 503) {
    return (status: ChessgamesFetchStatus.throttled, pgn: null);
  }

  final trimmed = body.trim();
  if (statusCode == 200 && trimmed.startsWith('[Event ')) {
    return (status: ChessgamesFetchStatus.ok, pgn: trimmed);
  }

  final lower = trimmed.toLowerCase();
  final softBan =
      lower.contains('too many requests') ||
      lower.contains('under maintenance') ||
      lower.contains('temporarily unavailable') ||
      lower.contains('rate limit');
  return (
    status: softBan
        ? ChessgamesFetchStatus.throttled
        : ChessgamesFetchStatus.failed,
    pgn: null,
  );
}

// ── Helpers ──────────────────────────────────────────────────────────────

String _unescapeHtml(String s) => s
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&apos;', "'")
    .replaceAll('&nbsp;', ' ');
