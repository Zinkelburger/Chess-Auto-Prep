import 'dart:convert';

import 'package:http/http.dart' as http;

import '../diagnostics/log.dart';

/// Downloading a Lichess study as PGN.
///
/// One request per study: Lichess serves every chapter, with its comments,
/// variations and board orientation, from one endpoint. Clocks are asked to
/// stay behind — they are noise in an opening file. A public study needs no
/// account; a private or unlisted one needs the user's token, which is read
/// at the call and never written to the log.

/// A Lichess study link the app knows how to fetch.
final class LichessStudyLink {
  const LichessStudyLink({required this.studyId, this.chapterId});

  /// The eight characters Lichess names a study by.
  final String studyId;

  /// Set when the link named one chapter, in which case only that chapter
  /// is downloaded.
  final String? chapterId;

  /// What the dialog echoes back, so the user can see what was recognised
  /// before they press the button.
  String get describe => chapterId == null
      ? 'Lichess study · $studyId'
      : 'Lichess study chapter · $studyId/$chapterId';

  @override
  bool operator ==(Object other) =>
      other is LichessStudyLink &&
      other.studyId == studyId &&
      other.chapterId == chapterId;

  @override
  int get hashCode => Object.hash(studyId, chapterId);
}

/// Lichess ids are exactly eight URL-safe characters.
final _lichessId = RegExp(r'^[A-Za-z0-9]{8}$');
final _scheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://');

/// [input] as a study link, or null when it is not one.
///
/// Pure, so the dialog can echo what it recognised on every keystroke. A
/// link with no scheme, with tracking parameters or with a trailing slug is
/// still the same study.
LichessStudyLink? parseStudyLink(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return null;
  final Uri uri;
  try {
    uri = Uri.parse(_scheme.hasMatch(trimmed) ? trimmed : 'https://$trimmed');
  } on FormatException {
    return null;
  }
  if (uri.host.toLowerCase().replaceFirst('www.', '') != 'lichess.org') {
    return null;
  }
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.length < 2 || segments.first != 'study') return null;
  if (!_lichessId.hasMatch(segments[1])) return null;
  return LichessStudyLink(
    studyId: segments[1],
    chapterId: segments.length >= 3 && _lichessId.hasMatch(segments[2])
        ? segments[2]
        : null,
  );
}

sealed class StudyFetch {
  const StudyFetch();
}

/// The study's PGN, every chapter of it.
final class StudyFetched extends StudyFetch {
  const StudyFetched(this.pgn);

  final String pgn;
}

/// Why the study did not arrive. Each is a sentence the dialog shows as it
/// is; nothing here reaches the log with a token in it.
enum StudyFetchProblem {
  unreachable(
    'Lichess did not respond (rate-limited or offline). Try again '
    'shortly.',
  ),
  notFound(
    'Study not found. If it is private or unlisted, sign in to '
    'Lichess first, then try again.',
  ),
  rejected(
    'Lichess rejected the request. Sign in to Lichess again, then try '
    'again.',
  ),
  empty('That study is empty — nothing to import.'),
  http('Lichess could not serve that study.');

  const StudyFetchProblem(this.sentence);

  final String sentence;
}

final class StudyNotFetched extends StudyFetch {
  const StudyNotFetched(this.problem, {this.status});

  final StudyFetchProblem problem;

  /// The HTTP status, when the problem was one.
  final int? status;

  String get sentence => status == null
      ? problem.sentence
      : '${problem.sentence} It answered HTTP $status.';
}

/// The network is a real boundary, so this is an interface: [LichessStudyApi]
/// in the app, a scripted one in tests, which never reach the network.
abstract interface class LichessStudies {
  Future<StudyFetch> fetch(LichessStudyLink link);
}

/// How long a download may take before it counts as not arriving.
///
/// A connection that is open but silent would otherwise hold the study
/// operations — one at a time — for as long as it stayed open, and every
/// action the user tried would answer that another change is running.
const studyDownloadTimeout = Duration(seconds: 20);

/// What the export endpoint is asked for: the things a study is made of,
/// without the clocks.
const _exportParams = {
  'clocks': 'false',
  'comments': 'true',
  'variations': 'true',
  'orientation': 'true',
};

final class LichessStudyApi implements LichessStudies {
  LichessStudyApi(this._client, {required Future<String?> Function() token})
    : _token = token;

  final http.Client _client;

  /// The user's Lichess token, read at the call so that signing in between
  /// two attempts is enough. Never logged.
  final Future<String?> Function() _token;

  @override
  Future<StudyFetch> fetch(LichessStudyLink link) async {
    final url = _url(link);
    final http.Response response;
    try {
      response = await _client
          .get(url, headers: await _headers())
          .timeout(studyDownloadTimeout);
    } on Object catch (error) {
      log.w('download the Lichess study ${link.studyId}', error);
      return const StudyNotFetched(StudyFetchProblem.unreachable);
    }
    final problem = _problemOf(response.statusCode);
    if (problem != null) {
      log.w(
        'download the Lichess study ${link.studyId}',
        'HTTP ${response.statusCode}',
      );
      return StudyNotFetched(
        problem,
        status: problem == StudyFetchProblem.http ? response.statusCode : null,
      );
    }
    // Lichess sends UTF-8 and does not spell the charset out for PGN, which
    // `response.body` would read as Latin-1.
    final pgn = const Utf8Decoder(
      allowMalformed: true,
    ).convert(response.bodyBytes);
    if (pgn.trim().isEmpty) {
      log.w('download the Lichess study ${link.studyId}', 'no games returned');
      return const StudyNotFetched(StudyFetchProblem.empty);
    }
    return StudyFetched(pgn);
  }

  StudyFetchProblem? _problemOf(int status) => switch (status) {
    200 => null,
    404 => StudyFetchProblem.notFound,
    401 || 403 => StudyFetchProblem.rejected,
    _ => StudyFetchProblem.http,
  };

  Future<Map<String, String>> _headers() async {
    final token = await _token();
    return {
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  /// Ids are checked before they get here, so encoding them is
  /// belt-and-braces; it costs nothing and keeps each one a single path
  /// segment whatever the caller did.
  Uri _url(LichessStudyLink link) {
    final id = Uri.encodeComponent(link.studyId);
    final chapter = link.chapterId;
    final path = chapter == null
        ? '$id.pgn'
        : '$id/${Uri.encodeComponent(chapter)}.pgn';
    return Uri.https('lichess.org', '/api/study/$path', _exportParams);
  }
}
