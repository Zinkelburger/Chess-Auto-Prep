import 'package:chess_auto_prep/net/lichess_study_writes.dart';
import 'package:dartchess/dartchess.dart' show Side;

/// A Lichess that takes what it is sent and remembers it, without the
/// network. Each new chapter gets the next id of [chapterIds].
final class ScriptedStudyWriter implements LichessStudyWriter {
  ScriptedStudyWriter({this.loggedIn = true});

  bool loggedIn;

  /// The id a new study gets.
  String studyId = 'wxyz9876';

  /// What every call answers instead, when set.
  LichessNotWritten? failing;

  /// Chapters to refuse, by name, as Lichess refuses one it cannot read.
  final refuse = <String>{};

  /// Chapters Lichess no longer has, by id.
  final gone = <String>{};

  final created = <String>[];
  final added = <({String study, String name, Side side, bool initial})>[];
  final replaced = <({String chapter, Map<String, String> tags})>[];
  final pgns = <String>[];
  var _next = 0;

  @override
  Future<bool> get signedIn async => loggedIn;

  @override
  Future<LichessWrite> create(String name) async {
    if (failing case final failed?) return failed;
    created.add(name);
    return LichessWritten(studyId);
  }

  @override
  Future<LichessWrite> addChapter(
    String study, {
    required String pgn,
    required String name,
    required Side orientation,
    bool initial = false,
  }) async {
    if (failing case final failed?) return failed;
    if (refuse.contains(name)) {
      return const LichessNotWritten(
        LichessWriteProblem.rejected,
        detail: 'Invalid PGN',
      );
    }
    added.add((study: study, name: name, side: orientation, initial: initial));
    pgns.add(pgn);
    return LichessWritten('chap${_next++}'.padRight(8, '0'));
  }

  @override
  Future<LichessWrite> replaceChapter(
    String study,
    String chapter, {
    required String pgn,
    required Map<String, String> tags,
  }) async {
    if (failing case final failed?) return failed;
    if (gone.contains(chapter)) {
      return const LichessNotWritten(LichessWriteProblem.notFound);
    }
    replaced.add((chapter: chapter, tags: tags));
    pgns.add(pgn);
    return const LichessWritten();
  }
}
