import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';

import '../chess/pgn/chapter.dart';
import '../chess/pgn/chapter_sections.dart';
import '../chess/pgn/game_tree.dart';
import '../diagnostics/log.dart';
import '../storage/chapter_files.dart';
import '../storage/pgn_document_store.dart';
import '../storage/settings_store.dart';
import 'document_session.dart';
import 'gap_walk.dart';
import 'replies.dart';

/// What a reply row says when the position after it is answered by another
/// line of the same chapter rather than by another chapter.
const hereLabel = 'this chapter';

/// Where in the open chapter the opponent's likely replies go unanswered:
/// the walk over the whole chapter, and the gap `Next gap` took the user
/// to.
///
/// Walks again when the chapter is another value or the rating or the
/// floor changed. Reads the [DocumentSession], the [SettingsStore] and,
/// through [RepertoireAnswers], the other chapters of the repertoire, so a
/// reply another chapter answers is not called a gap here; never holds a
/// copy of the tree or the cursor. Notifies when a walk starts or ends and
/// when the marked gap changes, not for every cursor move.
final class GapHunt extends ChangeNotifier {
  GapHunt({
    required DocumentSession session,
    required ReplyModel model,
    required SettingsStore settings,
    required RepertoireAnswers answers,
  }) : _session = session,
       _model = model,
       _settings = settings,
       _answers = answers {
    _session.anyChange.addListener(_follow);
    _settings.addListener(_follow);
    _follow();
  }

  final DocumentSession _session;
  final ReplyModel _model;
  final SettingsStore _settings;
  final RepertoireAnswers _answers;

  ChapterRef? _source;
  GapWalk? _walk;
  bool _walking = false;
  Gap? _highlighted;
  int _gapIndex = -1;

  /// The chapter value and the settings the current walk is for.
  ({Object chapter, int elo, int onceIn})? _walkedFor;

  /// Bumped for every walk and on dispose: a walk that finds it moved on
  /// was overtaken.
  int _ticket = 0;

  /// The last finished walk over the open chapter, or null before the
  /// first one finishes. Stale while [walking], and says so.
  GapWalk? get walk => _walk;

  bool get walking => _walking;

  /// The gap Next took the user to, until the cursor leaves it.
  Gap? get highlighted => _highlighted;

  /// Takes the board to the next gap, most reached first, round and round.
  /// A missing reply lands on the position before it, with the reply's row
  /// marked in the table; a dead end lands where the chapter stops.
  void nextGap() {
    final gaps = _walk?.gaps ?? const [];
    if (gaps.isEmpty) return;
    _gapIndex = (_gapIndex + 1) % gaps.length;
    final gap = gaps[_gapIndex];
    _highlighted = gap;
    _session.goTo(gap.at);
    notifyListeners();
  }

  /// Walks again when the chapter is another value or the rating or floor
  /// changed, and lets go of the marked gap when the cursor leaves it: a
  /// refusal, a flip or another setting changes nothing here.
  void _follow() {
    final chapter = _session.chapter;
    if (chapter == null) {
      if (_walkedFor != null || _highlighted != null) _clear();
      return;
    }
    var changed = false;
    if (_highlighted != null && _session.cursor != _highlighted!.at) {
      _highlighted = null;
      changed = true;
    }
    if (_session.source != _source) {
      // The chapter that was open may have been edited; what it answers is
      // read again the next time another chapter is walked.
      _source = _session.source;
      _answers.forget();
    }
    final s = _settings.value;
    final seen = _walkedFor;
    if (seen == null ||
        !identical(seen.chapter, chapter) ||
        seen.elo != s.opponentElo ||
        seen.onceIn != s.coverOnceIn) {
      _walkedFor = (
        chapter: chapter,
        elo: s.opponentElo,
        onceIn: s.coverOnceIn,
      );
      _rewalk();
      changed = true;
    }
    if (changed) notifyListeners();
  }

  void _clear() {
    _walk = null;
    _walking = false;
    _highlighted = null;
    _gapIndex = -1;
    _walkedFor = null;
    _ticket++;
    notifyListeners();
  }

  /// A repertoire chapter is walked; a single game of a file is not, since
  /// its gaps are not anybody's to fill.
  void _rewalk() {
    final ticket = ++_ticket;
    final chapter = _session.chapter!;
    if (_session.game != null) {
      _walk = null;
      _walking = false;
      return;
    }
    _walking = true;
    unawaited(
      _walked(
        ticket,
        chapter.tree,
        chapter.side,
        source: _session.source,
        floor: 1 / _settings.value.coverOnceIn,
      ),
    );
  }

  Future<void> _walked(
    int ticket,
    GameTree tree,
    Side side, {
    required ChapterRef? source,
    required double floor,
  }) async {
    bool overtaken() => ticket != _ticket;
    final elsewhere = {
      if (source != null) ...await _answers.around(source, side),
      for (final position in answeredPositions(tree, side)) position: hereLabel,
    };
    if (overtaken()) return;
    final walk = await walkGaps(
      tree: tree,
      side: side,
      floor: floor,
      shares: _model.sharesAt,
      overtaken: overtaken,
      elsewhere: elsewhere,
    );
    if (overtaken() || walk == null) return;
    _walk = walk;
    _walking = false;
    _gapIndex = -1;
    notifyListeners();
  }

  @override
  void dispose() {
    _ticket++;
    _session.anyChange.removeListener(_follow);
    _settings.removeListener(_follow);
    super.dispose();
  }
}

/// What the other chapters of a repertoire answer: for each position at
/// which one of them has a move of ours, the name of that chapter.
///
/// A gap is a position the opponent reaches often and the repertoire has
/// no answer for — the repertoire, not the page. A reply the Petroff
/// chapter answers is not a gap in the Italian one, whatever the Italian
/// file says. The other chapters are read from disk and their positions
/// kept until [forget]: the library says when its files change, and the
/// chapter that was just open may have been edited, so a change of chapter
/// forgets too. Draft chapters do not count; a proposal is not an answer.
final class RepertoireAnswers {
  RepertoireAnswers({
    required ChapterFiles files,
    required PgnDocumentStore documents,
  }) : _files = files,
       _documents = documents;

  final ChapterFiles _files;
  final PgnDocumentStore _documents;

  /// What each chapter answers, by chapter, as last read.
  final _read = <ChapterRef, _Answered>{};

  /// Drops what was read; the next question reads the files again.
  void forget() => _read.clear();

  /// The positions the chapters of [chapter]'s repertoire other than itself
  /// answer from [side], each naming the first chapter, in folder order,
  /// that answers it.
  Future<Map<String, String>> around(ChapterRef chapter, Side side) async {
    final listing = await _files.list();
    if (listing is! Repertoires) return const {};
    final folder = listing.folders
        .where((f) => f.chapters.any((c) => c.path == chapter.path))
        .firstOrNull;
    if (folder == null) return const {};
    final answers = <String, String>{};
    // A course file holds many chapters; it is read once for all of them.
    final files = <String, Future<Chapter?>>{};
    for (final other in folder.chapters) {
      // By chapter, not by file: the other chapters of a course file are
      // other chapters.
      if (other == chapter || other.heading.draft) continue;
      final answered = _read[other] ??= _answeredIn(
        other,
        await (files[other.path] ??= _file(other)),
      );
      if (answered.side != side) continue;
      for (final position in answered.positions) {
        answers.putIfAbsent(position, () => other.name);
      }
    }
    return answers;
  }

  _Answered _answeredIn(ChapterRef ref, Chapter? file) {
    if (file == null) return _Answered.none;
    final chapter = sectionView(file, ref.section).chapter;
    return _Answered(
      chapter.side,
      answeredPositions(chapter.tree, chapter.side),
    );
  }

  Future<Chapter?> _file(ChapterRef ref) async {
    switch (await _documents.open(ref)) {
      case Opened(:final text):
        return readChapter(name: ref.fileName, text: text);
      case Absent():
        return null;
      case Unreadable(:final detail):
        log.w('read what ${ref.path} answers', detail);
        return null;
    }
  }
}

final class _Answered {
  const _Answered(this.side, this.positions);

  static const none = _Answered(null, <String>{});

  /// Null for a chapter that could not be read, which answers nothing.
  final Side? side;

  final Set<String> positions;
}
