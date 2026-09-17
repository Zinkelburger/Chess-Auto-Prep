/// Recognising the URLs Study import accepts: Lichess studies and
/// chessgames.com collections.
///
/// Pure parsing — no I/O, so the import dialog can echo back what it
/// recognised on every keystroke.  Fetching lives in
/// `lichess_study_client.dart` / `chessgames_collection_client.dart`.
library;

/// A downloadable source of chapters, identified from a pasted URL.
sealed class ImportSource {
  const ImportSource();

  /// Short "what this is" line for the dialog (e.g. `Lichess study · WcJ8Iyaz`).
  String get label;
}

/// One Lichess study — every chapter, or just [chapterId] when the URL
/// pointed at a single chapter.
class LichessStudySource extends ImportSource {
  const LichessStudySource({required this.studyId, this.chapterId});

  final String studyId;

  /// Non-null when the URL named a chapter (`/study/<id>/<chapterId>`).
  final String? chapterId;

  @override
  String get label => chapterId == null
      ? 'Lichess study · $studyId'
      : 'Lichess study chapter · $studyId/$chapterId';

  @override
  bool operator ==(Object other) =>
      other is LichessStudySource &&
      other.studyId == studyId &&
      other.chapterId == chapterId;

  @override
  int get hashCode => Object.hash(studyId, chapterId);
}

/// Every public study belonging to one Lichess user.
class LichessUserStudiesSource extends ImportSource {
  const LichessUserStudiesSource(this.username);

  final String username;

  @override
  String get label => "Lichess · all of $username's studies";

  @override
  bool operator ==(Object other) =>
      other is LichessUserStudiesSource && other.username == username;

  @override
  int get hashCode => username.hashCode;
}

/// A chessgames.com game collection, identified by its `cid`.
class ChessgamesCollectionSource extends ImportSource {
  const ChessgamesCollectionSource(this.cid);

  final String cid;

  @override
  String get label => 'chessgames.com collection · cid $cid';

  @override
  bool operator ==(Object other) =>
      other is ChessgamesCollectionSource && other.cid == cid;

  @override
  int get hashCode => cid.hashCode;
}

// ── Parsing ──────────────────────────────────────────────────────────────

/// Lichess ids are exactly 8 URL-safe characters.
final _lichessId = RegExp(r'^[A-Za-z0-9]{8}$');

/// Lichess usernames: letters, digits, `_` and `-`, 2–30 chars.
final _lichessUsername = RegExp(r'^[A-Za-z0-9_-]{2,30}$');

final _digits = RegExp(r'^\d+$');

/// Recognise [input] as an [ImportSource], or return `null`.
///
/// Accepts URLs with or without a scheme (`lichess.org/study/…` is fine) and
/// tolerates surrounding whitespace, tracking query params, and `#fragments`.
ImportSource? parseImportSource(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return null;

  // `Uri.parse` reads a scheme-less string as a bare path with no host, so
  // give it one before asking for the host.
  final withScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(trimmed)
      ? trimmed
      : 'https://$trimmed';

  final Uri uri;
  try {
    uri = Uri.parse(withScheme);
  } on FormatException {
    return null;
  }

  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();

  if (host == 'lichess.org') return _parseLichess(segments);
  if (host == 'chessgames.com') return _parseChessgames(uri);
  return null;
}

ImportSource? _parseLichess(List<String> segments) {
  if (segments.isEmpty || segments.first != 'study') return null;

  // /study/by/<username>
  if (segments.length >= 3 && segments[1] == 'by') {
    final username = segments[2];
    return _lichessUsername.hasMatch(username)
        ? LichessUserStudiesSource(username)
        : null;
  }

  if (segments.length < 2) return null;
  final studyId = segments[1];
  if (!_lichessId.hasMatch(studyId)) return null;

  // /study/<studyId>/<chapterId> — anything else after the id (embed URLs,
  // trailing slugs) is ignored and the whole study is imported.
  final chapterId = segments.length >= 3 && _lichessId.hasMatch(segments[2])
      ? segments[2]
      : null;
  return LichessStudySource(studyId: studyId, chapterId: chapterId);
}

ImportSource? _parseChessgames(Uri uri) {
  final cid = uri.queryParameters['cid']?.trim();
  if (cid == null || !_digits.hasMatch(cid)) return null;
  return ChessgamesCollectionSource(cid);
}
