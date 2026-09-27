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

import '../../services/chess_api_urls.dart';
import 'package:http/http.dart' as http;
import '../../chess_core/pgn/pgn_text.dart'
    show splitPgnIntoGames, extractHeaders;
import '../../features/studies/models/chapter_naming.dart';
import '../../features/studies/models/import_source.dart';
import '../../features/studies/models/study_import_exception.dart';

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
/// Throws [StudyImportException] with typed failure data when the
/// study is missing, private, or the request fails outright.
Future<FetchedStudy> fetchLichessStudy(
  ImportSource source, {
  required Future<http.Response?> Function(Uri) get,
  required bool loggedIn,
}) async {
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

  final response = await get(url);

  if (response == null) {
    throw const StudyImportException(StudySourceFailure.offline);
  }
  if (response.statusCode == 404) {
    throw switch (source) {
      LichessUserStudiesSource(:final username) => StudyImportException(
        StudySourceFailure.userMissing,
        username: username,
      ),
      _ => StudyImportException(
        loggedIn
            ? StudySourceFailure.scopeRequired
            : StudySourceFailure.loginRequired,
      ),
    };
  }
  if (response.statusCode == 401 || response.statusCode == 403) {
    throw const StudyImportException(StudySourceFailure.rejected);
  }
  if (response.statusCode != 200) {
    throw StudyImportException(
      StudySourceFailure.http,
      statusCode: response.statusCode,
    );
  }

  // Lichess sends UTF-8; `response.body` would decode it as latin-1 unless the
  // charset is spelled out in the content-type, which it is not for PGN.
  final pgn = const Utf8Decoder(
    allowMalformed: true,
  ).convert(response.bodyBytes);
  if (pgn.trim().isEmpty) {
    throw const StudyImportException(StudySourceFailure.empty);
  }

  final fallbackName = switch (source) {
    LichessUserStudiesSource(:final username) => '$username studies',
    LichessStudySource(:final studyId) => 'Lichess study $studyId',
    _ => 'Lichess study',
  };
  final split = splitLichessStudyName(pgn);
  return (pgn: split.pgn, name: split.studyName ?? fallbackName);
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
