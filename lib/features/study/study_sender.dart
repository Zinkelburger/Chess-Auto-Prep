import 'package:flutter/foundation.dart';

import '../../chess/pgn/chapter.dart';
import '../../chess/pgn/chapter_line.dart';
import '../../chess/pgn/game_text.dart';
import '../../chess/pgn/study.dart';
import '../../chess/pgn/study_cleanup.dart';
import '../../chess/pgn/study_lichess.dart';
import '../../net/lichess_studies.dart';
import '../../storage/chapter_files.dart' show ChapterRef;
import '../../net/lichess_study_writes.dart';
import '../../workspace/document_session.dart';
import 'study_commands.dart' show studyNameOf;

/// Sending the open study to the user's Lichess account, one send at a time.
///
/// Each chapter goes as its own request, so it keeps its name and the side
/// it is seen from. A chapter that came from the study being sent to, or
/// was sent there before, names its Lichess chapter in `ChapterURL`: its
/// moves and tags are put in place of Lichess's and it keeps its place
/// there. Every other chapter is added. The chapters Lichess made are then
/// written into the study as `ChapterURL`, as one undoable edit, so sending
/// again updates them instead of adding them twice.
final class StudySender extends ChangeNotifier {
  StudySender(this._writer, this._session, {required this.openPage});

  final LichessStudyWriter _writer;
  final DocumentSession _session;

  /// Shows a page in the desktop's browser; whether it went.
  final Future<bool> Function(Uri) openPage;

  StudySend _state = const SendIdle();
  bool _disposed = false;

  StudySend get state => _state;

  /// Lichess keeps at most this many chapters in one study.
  static const maxChapters = 64;

  /// The Lichess study the open study's chapters name, when they name one
  /// and only one: where sending goes back to by default.
  String? linkedStudy(Chapter chapter) {
    final studies = {
      for (final line in chapter.lines)
        if (tagValue(line.tags, chapterUrlTag) case final url?)
          if (parseStudyLink(url) case final link?) link.studyId,
    };
    return studies.length == 1 ? studies.single : null;
  }

  /// Sends the open study: into the Lichess study [into], or into a new
  /// private one when it is null.
  Future<void> send({String? into}) async {
    if (_state is Sending) return;
    final chapter = _session.snapshot();
    final source = _session.source;
    final problem = chapter == null || source == null
        ? const SendFailed('Open a study first.')
        : into == null && chapter.lines.length > maxChapters
        ? const SendFailed(
            'Lichess keeps at most $maxChapters chapters in a study. Split '
            'this one first.',
          )
        : !await _writer.signedIn
        ? SendFailed.of(LichessWriteProblem.signedOut)
        : null;
    if (problem != null) {
      _set(problem);
      return;
    }
    _set(Sending(0, chapter!.lines.length));
    final study = into ?? await _created(chapter);
    if (study == null) return;
    final run = _Run(study, fresh: into == null);
    for (final (index, line) in chapter.lines.indexed) {
      if (_disposed) return;
      _set(Sending(index, chapter.lines.length));
      if (await _sent(run, index, line, studyNameIn(chapter.lines)) == false) {
        break;
      }
    }
    if (_disposed) return;
    _record(source!, run.urls);
    _set(switch (run.failure) {
      final failed? => SendFailed(
        run.added + run.updated == 0
            ? failed.sentence
            : '${failed.sentence} ${_counted(run.added, run.updated)} before '
                  'it stopped; sending again picks up from there.',
        login: failed.problem.needsLogin,
        study: study,
      ),
      null => SendDone(
        study,
        added: run.added,
        updated: run.updated,
        skipped: run.skipped,
      ),
    });
  }

  /// A new private study named after [chapter]'s, or null when Lichess
  /// would not make one, with the reason on screen.
  Future<String?> _created(Chapter chapter) async {
    final created = await _writer.create(_lichessName(studyNameOf(chapter)));
    switch (created) {
      case LichessNotWritten(:final problem, :final sentence):
        _set(SendFailed(sentence, login: problem.needsLogin));
        return null;
      case LichessWritten(:final id?):
        return id;
      case LichessWritten():
        _set(SendFailed.of(LichessWriteProblem.http));
        return null;
    }
  }

  /// Sends chapter [index]: in place of the Lichess chapter it names in
  /// [run]'s study, else as a new one. False when Lichess refused it and
  /// the send stops; null when it could not be read whole and stays here.
  Future<bool?> _sent(
    _Run run,
    int index,
    ChapterLine line,
    String? study,
  ) async {
    final pgn = lichessChapterPgn(line);
    if (pgn == null) {
      run.skipped++;
      return null;
    }
    final link = switch (tagValue(line.tags, chapterUrlTag)) {
      final url? => parseStudyLink(url),
      null => null,
    };
    LichessWrite? result;
    if (!run.fresh && link?.studyId == run.study && link?.chapterId != null) {
      result = await _writer.replaceChapter(
        run.study,
        link!.chapterId!,
        pgn: pgn,
        tags: lichessTagsOf(line),
      );
      if (result is LichessWritten) run.updated++;
      // A chapter deleted on Lichess since is sent again as a new one.
      if (result case LichessNotWritten(
        problem: LichessWriteProblem.notFound,
      )) {
        result = null;
      }
    }
    result ??= await _writer.addChapter(
      run.study,
      pgn: pgn,
      name: _lichessName(studyChapterName(line, index: index, study: study)),
      orientation: studyOrientation(line),
      // A new study comes with an empty chapter; the first one sent takes
      // its place.
      initial: run.fresh && run.added == 0,
    );
    switch (result) {
      case LichessNotWritten failed:
        run.failure = failed;
        return false;
      case LichessWritten(:final id?):
        run.added++;
        run.urls[index] = chapterUrl(run.study, id);
      case LichessWritten():
    }
    return true;
  }

  /// The study a Lichess study or chapter link names, or null.
  static String? studyIn(String link) => parseStudyLink(link)?.studyId;

  /// The page of a Lichess study.
  static Uri studyPage(String study) =>
      Uri.https('lichess.org', '/study/$study');

  /// The `ChapterURL` Lichess's own export gives a chapter.
  static String chapterUrl(String study, String chapter) =>
      'https://lichess.org/study/$study/$chapter';

  /// Back to the start, for the next send.
  void reset() {
    if (_state is! Sending) _set(const SendIdle());
  }

  /// Where the chapters Lichess made live, written into the study they were
  /// sent from while it is still the one open.
  void _record(ChapterRef source, Map<int, String> urls) {
    if (urls.isEmpty || _session.source != source) return;
    _session.apply((now) => withStudyTag(now, chapterUrlTag, urls));
  }

  static String _counted(int added, int updated) => [
    if (added > 0) '$added ${added == 1 ? 'chapter' : 'chapters'} added',
    if (updated > 0) '$updated updated',
  ].join(', ').replaceFirstMapped(RegExp('^.'), (m) => m[0]!.toUpperCase());

  /// Lichess names are at most 100 characters.
  static String _lichessName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Study';
    return trimmed.length <= 100 ? trimmed : trimmed.substring(0, 100);
  }

  void _set(StudySend state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Where a send stands.
sealed class StudySend {
  const StudySend();
}

final class SendIdle extends StudySend {
  const SendIdle();
}

/// [done] of [total] chapters gone.
final class Sending extends StudySend {
  const Sending(this.done, this.total);

  final int done, total;
}

final class SendDone extends StudySend {
  const SendDone(
    this.study, {
    required this.added,
    required this.updated,
    required this.skipped,
  });

  /// The Lichess study the chapters went to.
  final String study;
  final int added, updated;

  /// Chapters that could not be read whole, and stayed here.
  final int skipped;
}

final class SendFailed extends StudySend {
  const SendFailed(this.sentence, {this.login = false, this.study});

  SendFailed.of(LichessWriteProblem problem)
    : this(problem.sentence, login: problem.needsLogin);

  final String sentence;

  /// Logging in (again) is the way out.
  final bool login;

  /// The Lichess study made or written to before it stopped, if any.
  final String? study;
}

/// One send's progress through the chapters.
final class _Run {
  _Run(this.study, {required this.fresh});

  /// The Lichess study the chapters go to.
  final String study;

  /// Made by this send, so nothing in it is the study's yet.
  final bool fresh;

  /// The `ChapterURL` of each chapter Lichess made, by its place here.
  final urls = <int, String>{};
  var added = 0, updated = 0, skipped = 0;
  LichessNotWritten? failure;
}
