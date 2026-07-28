/// Fetching a Lichess study as PGN, and tidying the chapter names it comes
/// back with.
///
/// One request, no pacing needed — Lichess serves the whole study (every
/// chapter, comments and variations included) from a single endpoint.  Public
/// studies need no auth; private ones need a token carrying the `study:read`
/// scope, which [LichessApiClient] attaches automatically when the user is
/// logged in.
library;

import 'dart:convert';

import '../chess_api_urls.dart';
import '../lichess_api_client.dart';
import '../lichess_auth_service.dart';
import '../pgn_parsing_service.dart' show splitPgnIntoGames, extractHeaders;
import 'chapter_naming.dart';
import 'import_source.dart';
import 'study_import_exception.dart';

/// Export options. Comments and variations are the point of a study; clocks
/// are noise in an opening file.
const _exportParams = {
  'clocks': 'false',
  'comments': 'true',
  'variations': 'true',
  'orientation': 'true',
};

/// A downloaded study: multi-game PGN plus the name to file it under.
typedef FetchedStudy = ({String pgn, String name});

/// Download [source] as PGN, with chapter names already normalised.
///
/// Throws [StudyImportException] with a message fit for a SnackBar when the
/// study is missing, private, or the request fails outright.
Future<FetchedStudy> fetchLichessStudy(ImportSource source) async {
  final url = switch (source) {
    LichessStudySource(:final studyId, :final chapterId) => lichessStudyPgnUrl(
      studyId,
      _exportParams,
      chapterId: chapterId,
    ),
    LichessUserStudiesSource(:final username) => lichessStudiesByUserUrl(
      username,
      _exportParams,
    ),
    _ => throw ArgumentError('Not a Lichess source: $source'),
  };

  final response = await LichessApiClient.instance.get(
    url,
    extraHeaders: {'Accept': 'application/x-chess-pgn'},
  );

  if (response == null) {
    throw const StudyImportException(
      'Lichess did not respond (rate-limited or offline). Try again shortly.',
    );
  }
  if (response.statusCode == 404) {
    throw StudyImportException(_notFoundMessage(source));
  }
  if (response.statusCode == 401 || response.statusCode == 403) {
    throw const StudyImportException(
      'Lichess rejected the request. Log out and back in under Lichess '
      'settings, then try again.',
    );
  }
  if (response.statusCode != 200) {
    throw StudyImportException('Lichess returned HTTP ${response.statusCode}.');
  }

  // Lichess sends UTF-8; `response.body` would decode it as latin-1 unless the
  // charset is spelled out in the content-type, which it is not for PGN.
  final pgn = const Utf8Decoder(
    allowMalformed: true,
  ).convert(response.bodyBytes);
  if (pgn.trim().isEmpty) {
    throw const StudyImportException(
      'That study is empty — nothing to import.',
    );
  }

  final fallbackName = switch (source) {
    LichessUserStudiesSource(:final username) => '$username studies',
    LichessStudySource(:final studyId) => 'Lichess study $studyId',
    _ => 'Lichess study',
  };
  final split = splitLichessStudyName(pgn);
  return (pgn: split.pgn, name: split.studyName ?? fallbackName);
}

String _notFoundMessage(ImportSource source) {
  if (source is LichessUserStudiesSource) {
    return 'No public studies found for "${source.username}".';
  }
  final auth = LichessAuthService.instance;
  if (!auth.isLoggedIn) {
    return 'Study not found. If it is private or unlisted, log into Lichess '
        'first (Lichess settings → Log in), then try again.';
  }
  // Lichess answers "private study, insufficient scope" with a plain 404, so a
  // logged-in miss is most often a token minted before we asked for
  // `study:read`.
  return 'Study not found. If it is private, your Lichess login predates '
      'study access — log out and back in to grant it.';
}

// ── Chapter naming ───────────────────────────────────────────────────────

/// Lichess names every exported chapter `[Event "Study name: Chapter name"]`.
///
/// Importing that verbatim gives a study whose chapters all repeat the study's
/// own name.  When every game shares one prefix, return it as the study name
/// and rewrite each `[Event]` down to the chapter name alone; otherwise leave
/// the PGN untouched.
({String? studyName, String pgn}) splitLichessStudyName(String pgn) {
  final games = splitPgnIntoGames(pgn);
  if (games.isEmpty) return (studyName: null, pgn: pgn);

  String? prefix;
  final chapterNames = <String>[];
  for (final game in games) {
    final event = extractHeaders(game)['Event']?.trim() ?? '';
    final sep = event.indexOf(': ');
    if (sep <= 0 || sep + 2 >= event.length) return (studyName: null, pgn: pgn);
    final head = event.substring(0, sep);
    if (prefix != null && head != prefix) return (studyName: null, pgn: pgn);
    prefix = head;
    chapterNames.add(event.substring(sep + 2).trim());
  }

  final rewritten = [
    for (var i = 0; i < games.length; i++)
      withEventHeader(games[i], chapterNames[i]),
  ];
  return (studyName: prefix, pgn: rewritten.join('\n\n'));
}
