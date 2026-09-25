import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';

import '../chess/pgn/chapter.dart';
import '../chess/pgn/chapter_sections.dart';
import '../chess/pgn/game_tree.dart';
import '../storage/chapter_files.dart';
import '../storage/document_ref.dart';
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
    required this._session,
    required this._model,
    required this._settings,
    required this._answers,
  }) {
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
  String? _problem;
  RepertoireAnswerSnapshot? _snapshot;
  bool _navigating = false;

  /// The chapter value and the settings the current walk is for.
  ({Object chapter, int elo, int onceIn, (String, String?)? source})?
  _walkedFor;

  /// Bumped for every walk and on dispose: a walk that finds it moved on
  /// was overtaken.
  int _ticket = 0;

  /// The last finished walk over the open chapter, or null before the
  /// first one over it finishes. While [walking] after an edit it is the
  /// walk before the edit, and says so; another chapter never shows this
  /// one's.
  GapWalk? get walk => _walk;

  bool get walking => _walking;
  String? get problem => _problem;
  GapWalk? get currentWalk => !_walking && _problem == null ? _walk : null;
  bool get canNextGap =>
      !_navigating && (currentWalk?.gaps.isNotEmpty ?? false);

  /// The gap Next took the user to, until the cursor leaves it.
  Gap? get highlighted => _highlighted;

  /// Committed sibling changes can add or remove answers without changing the
  /// open chapter. Cancel the old walk and discard its navigation targets.
  void refreshAnswers() {
    _answers.forget();
    _clear();
    _follow();
  }

  /// Takes the board to the next gap, most reached first, round and round.
  /// A missing reply lands on the position before it, with the reply's row
  /// marked in the table; a dead end lands where the chapter stops.
  Future<void> nextGap() async {
    if (!canNextGap) return;
    final walk = currentWalk!;
    final index = (_gapIndex + 1) % walk.gaps.length;
    final gap = walk.gaps[index];
    final ticket = _ticket;
    _navigating = true;
    notifyListeners();
    try {
      if (!await validateCurrent() ||
          ticket != _ticket ||
          !identical(walk, currentWalk)) {
        return;
      }
      _gapIndex = index;
      _highlighted = gap;
      _session.goTo(gap.at);
    } finally {
      _navigating = false;
      if (ticket == _ticket) notifyListeners();
    }
  }

  /// Revalidate the captured membership and sources before using gap authority.
  Future<bool> validateCurrent() async {
    final ticket = _ticket;
    if (currentWalk == null) return false;
    try {
      await _snapshot?.validate();
      return ticket == _ticket && currentWalk != null;
    } on Object catch (error) {
      if (ticket == _ticket) _failed(error);
      return false;
    }
  }

  void retry() => refreshAnswers();

  void _failed(Object error) {
    _problem = '$error';
    _walking = false;
    _highlighted = null;
    _gapIndex = -1;
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
      // The chapter that was open may have been edited; what its file
      // answers is read again the next time another chapter is walked.
      if (_source case final left?) _answers.forgetFile(left.path);
      _source = _session.source;
      // Its gaps are places in its tree, not in this one's.
      _walk = null;
      _highlighted = null;
      _gapIndex = -1;
      changed = true;
    }
    final s = _settings.value;
    final seen = _walkedFor;
    final revision = _session.persistedRevision;
    final sourceProof = revision == null
        ? null
        : (revision.contentHash, revision.nativeIdentity);
    if (seen == null ||
        !identical(seen.chapter, chapter) ||
        seen.elo != s.opponentElo ||
        seen.onceIn != s.coverOnceIn ||
        seen.source != sourceProof) {
      _walkedFor = (
        chapter: chapter,
        elo: s.opponentElo,
        onceIn: s.coverOnceIn,
        source: sourceProof,
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
    _problem = null;
    _snapshot = null;
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
    _problem = null;
    _highlighted = null;
    _gapIndex = -1;
    unawaited(
      _walked(
        ticket,
        chapter.tree,
        chapter.side,
        source: _session.source,
        floor: 1 / _settings.value.coverOnceIn,
        revision: _session.persistedRevision,
      ),
    );
  }

  Future<void> _walked(
    int ticket,
    GameTree tree,
    Side side, {
    required ChapterRef? source,
    required double floor,
    required Revision? revision,
  }) async {
    bool overtaken() => ticket != _ticket;
    try {
      final snapshot = source == null
          ? null
          : await _answers.capture(
              source,
              side,
              observed: {source.path: ?revision},
            );
      if (overtaken()) return;
      final elsewhere = Map<String, String>.unmodifiable({
        ...?snapshot?.positions,
        for (final position in answeredPositions(tree, side))
          position: hereLabel,
      });
      final walk = await walkGaps(
        tree: tree,
        side: side,
        floor: floor,
        shares: _model.sharesAt,
        overtaken: overtaken,
        elsewhere: elsewhere,
      );
      if (overtaken() || walk == null) return;
      await snapshot?.validate();
      if (overtaken()) return;
      _walk = walk;
      _snapshot = snapshot;
      _walking = false;
      _gapIndex = -1;
      notifyListeners();
    } on Object catch (error) {
      if (!overtaken()) _failed(error);
    }
  }

  @override
  void dispose() {
    _ticket++;
    _session.anyChange.removeListener(_follow);
    _settings.removeListener(_follow);
    super.dispose();
  }
}

/// An immutable answer projection and the complete native read set that
/// authorized it. Revalidation never interprets a failed read as empty.
final class RepertoireAnswerSnapshot {
  RepertoireAnswerSnapshot._(
    this._owner,
    this._generation,
    this.listing,
    Map<String, Revision> observed,
    Map<String, String> positions,
  ) : observed = Map.unmodifiable(observed),
      positions = Map.unmodifiable(positions);

  final RepertoireAnswers _owner;
  final int _generation;
  final Repertoires listing;
  final Map<String, Revision> observed;
  final Map<String, String> positions;

  Future<void> validate() => _owner._validate(this);
}

final class RepertoireAnswersUnavailable implements Exception {
  const RepertoireAnswersUnavailable(this.detail);
  final String detail;
  @override
  String toString() => detail;
}

/// Revision-keyed answering positions, bounded to the latest membership.
/// Every query observes source files again; only successful parsing is cached.
final class RepertoireAnswers {
  RepertoireAnswers({required this._files, required this._documents});

  final ChapterFiles _files;
  final PgnDocumentStore _documents;
  var _read = <ChapterRef, ({Revision revision, _Answered answer})>{};
  int _generation = 0;

  void forget() {
    _generation++;
    _read = {};
  }

  void forgetFile(String path) {
    _generation++;
    _read = {
      for (final entry in _read.entries)
        if (entry.key.path != path) entry.key: entry.value,
    };
  }

  Future<Map<String, String>> around(ChapterRef chapter, Side side) async =>
      (await capture(chapter, side)).positions;

  Future<RepertoireAnswerSnapshot> capture(
    ChapterRef chapter,
    Side side, {
    Map<String, Revision> observed = const {},
  }) async {
    final generation = _generation;
    final revisions = Map<String, Revision>.of(observed);
    final listing = await _files.list();
    if (listing is! Repertoires) {
      throw RepertoireAnswersUnavailable(
        (listing as RepertoiresUnreadable).detail,
      );
    }
    if (listing.unreadable.isNotEmpty) {
      throw RepertoireAnswersUnavailable(listing.unreadable.first.detail);
    }
    final folder = listing.folders
        .where(
          (folder) => folder.chapters.any((ref) => ref.path == chapter.path),
        )
        .firstOrNull;
    final members = {for (final folder in listing.folders) ...folder.chapters};
    final next = {
      for (final entry in _read.entries)
        if (members.contains(entry.key)) entry.key: entry.value,
    };
    final positions = <String, String>{};
    final byFile = <String, List<ChapterRef>>{};
    for (final other in List<ChapterRef>.of(folder?.chapters ?? const [])) {
      if (other != chapter && !other.heading.draft) {
        (byFile[other.path] ??= []).add(other);
      }
    }
    // Materialize one PGN at a time, retaining only its answering positions.
    for (final siblings in byFile.values) {
      final answered = await _answeredFile(
        siblings,
        revisions[siblings.first.path],
      );
      revisions[siblings.first.path] = answered.values.first.revision;
      next.addAll(answered);
      for (final entry in answered.entries) {
        if (entry.value.answer.side != side) continue;
        for (final position in entry.value.answer.positions) {
          positions.putIfAbsent(position, () => entry.key.name);
        }
      }
    }
    final snapshot = RepertoireAnswerSnapshot._(
      this,
      generation,
      listing,
      revisions,
      positions,
    );
    await snapshot.validate();
    _read = next;
    return snapshot;
  }

  Future<Map<ChapterRef, ({Revision revision, _Answered answer})>>
  _answeredFile(List<ChapterRef> siblings, Revision? expected) async {
    final first = siblings.first;
    final read = await _documents.open(first);
    if (read is! Opened) {
      throw RepertoireAnswersUnavailable(
        read is Unreadable ? read.detail : '${first.name} is missing.',
      );
    }
    if (expected != null && !sameChapterRevision(expected, read.revision)) {
      throw const RepertoireAnswersUnavailable(
        'The open chapter changed on disk. Reload it and retry.',
      );
    }
    Chapter? parsed;
    final result = <ChapterRef, ({Revision revision, _Answered answer})>{};
    for (final ref in siblings) {
      final cached = _read[ref];
      final _Answered answer;
      if (cached != null && cached.revision == read.revision) {
        answer = cached.answer;
      } else {
        parsed ??= await readChapter(name: first.fileName, text: read.text);
        final section = sectionView(parsed, ref.section).chapter;
        answer = _Answered(
          section.side,
          Set.unmodifiable(answeredPositions(section.tree, section.side)),
        );
      }
      result[ref] = (revision: read.revision, answer: answer);
    }
    return result;
  }

  Future<void> _validate(RepertoireAnswerSnapshot snapshot) async {
    if (snapshot._generation != _generation) {
      throw const RepertoireAnswersUnavailable(
        'The repertoire changed. Retry finding gaps.',
      );
    }
    final result = await _files.validate(
      snapshot.listing,
      observed: snapshot.observed,
    );
    if (snapshot._generation != _generation || result is RepertoireChanged) {
      throw const RepertoireAnswersUnavailable(
        'The repertoire changed. Retry finding gaps.',
      );
    }
    if (result is RepertoireValidationFailed) {
      throw RepertoireAnswersUnavailable(result.detail);
    }
  }
}

final class _Answered {
  const _Answered(this.side, this.positions);
  final Side side;
  final Set<String> positions;
}
