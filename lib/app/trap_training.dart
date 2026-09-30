import 'package:dartchess/dartchess.dart' show Side;

import '../chess/generation/draft_chapter.dart';
import '../chess/pgn/chapter.dart';
import '../chess/pgn/chapter_heading.dart';
import '../chess/pgn/tree_edit.dart';
import '../features/library/library.dart';
import '../features/trainer/trainer.dart';
import '../storage/chapter_files.dart';
import '../storage/finds_store.dart';
import '../storage/pgn_document_store.dart';
import '../workspace/document_session.dart';
import '../workspace/generated_draft.dart';
import 'mode.dart';
import 'workspace_requests.dart';

/// `Train this line` on a trap in the Positions list: the trap's whole line
/// — our moves, their mistake and our answer — drilled in the builder's
/// Train tab.
///
/// The line is looked for in the open repertoire chapter, then in the other
/// chapters of its repertoire; the first that plays it is opened at its end
/// and the line holding it trained. A line no chapter plays yet can go into
/// the open chapter's draft first, which [train]'s `addToDraft` asks about:
/// the draft beside the chapter for the line's side and start, or a new
/// one ([newDraftBeside]), and the line added to it as one edit. Whatever stops it is said in the
/// status bar; a chapter the user leaves on the way ends it quietly.
final class TrapTraining {
  TrapTraining({
    required this.requests,
    required this.session,
    required this.library,
    required this.trainer,
    required this.documents,
    DateTime Function() now = DateTime.now,
  }) : _now = now;

  final WorkspaceRequests requests;
  final DocumentSession session;
  final Library library;
  final Trainer trainer;

  /// Where a new draft is written.
  final PgnDocumentStore documents;

  /// What a new draft's heading says it was created on.
  final DateTime Function() _now;

  /// Trains [kept]'s line, asking [addToDraft] with the draft's name first
  /// when it has to go into one. The window's [showTrain] puts the
  /// builder's Train tab up just before the sitting starts, which it needs:
  /// a sitting ends when its tab is not open. True when one started.
  Future<bool> train(
    KeptFind kept, {
    required Future<bool> Function(String draft) addToDraft,
    required void Function() showTrain,
  }) async {
    final source = session.source;
    final chapter = session.chapter;
    final side = kept.side == Side.white ? 'White' : 'Black';
    if (source == null ||
        chapter == null ||
        chapter.game != null ||
        chapter.side != kept.side) {
      requests.say('Open a repertoire chapter for $side to train it.');
      return false;
    }
    final sans = kept.find.sans;
    if (!_sameRoot(chapter, kept)) {
      requests.say('This line starts where the chapter does not.');
      return false;
    }
    final holder = _plays(chapter, kept)
        ? source
        : await _chapterPlaying(source, kept);
    if (session.source != source) return false;
    if (holder != null) {
      if (await requests.readInBuilder(holder, sans) is! RequestDone) {
        return false;
      }
      return _trainOpen(sans, showTrain);
    }
    return _trainInDraft(kept, source, chapter, addToDraft, showTrain);
  }

  /// The line put into [source]'s draft, then trained there. The draft is
  /// worked out before asking, so the question names the draft the line
  /// goes into, and again after: a draft made or renamed while the question
  /// was up that changes which one that is stops it.
  Future<bool> _trainInDraft(
    KeptFind kept,
    ChapterRef source,
    Chapter chapter,
    Future<bool> Function(String draft) addToDraft,
    void Function() showTrain,
  ) async {
    final asked = await _draftFor(source, kept);
    if (session.source != source) return false;
    if (asked == null) {
      requests.say('Too many drafts of ${source.name}; delete some first.');
      return false;
    }
    if (!await addToDraft(asked.name) || session.source != source) {
      return false;
    }
    final target = await _draftFor(source, kept);
    if (session.source != source) return false;
    if (target == null || target.name != asked.name) {
      requests.say('The drafts of ${source.name} changed. Try again.');
      return false;
    }
    final made = await publishDraft(
      target,
      documents: documents,
      textFor: (name) => draftHeading(
        name: name,
        side: chapter.side,
        rootMoves: readHeading(chapter.preamble).rootMoves,
        created: _now(),
      ),
    );
    if (session.source != source) return false;
    final draft = switch (made) {
      DraftWritten(:final ref) => ref,
      DraftNotWritten() => null,
    };
    if (draft == null) {
      requests.say('Could not make the draft ${target.name}.');
      return false;
    }
    if (await requests.readInBuilder(draft, const []) is! RequestDone ||
        session.source != draft) {
      return false;
    }
    final refused = session.apply((c) => lineAdded(c, kept.find.sans));
    if (refused != null || !_played(kept)) {
      requests.say('Could not add the line to ${draft.name}.');
      return false;
    }
    return _trainOpen(kept.find.sans, showTrain);
  }

  /// The draft [kept]'s line goes into, from the list as it is now: the
  /// first draft beside [source] for the line's side and start, or else a
  /// new one. Null when every draft name is taken.
  Future<DraftTarget?> _draftFor(ChapterRef source, KeptFind kept) async {
    final chapters = library.repertoires.expand((f) => f.chapters).toList();
    for (final ref in draftsBeside(source, chapters)) {
      final draft = await library.chapterForSearch(ref);
      if (draft != null && draft.side == kept.side && _sameRoot(draft, kept)) {
        return ExistingDraft(ref);
      }
    }
    return newDraftBeside(source, chapters);
  }

  /// The first other chapter of [source]'s repertoire that plays the line.
  Future<ChapterRef?> _chapterPlaying(ChapterRef source, KeptFind kept) async {
    final folder = library.repertoires
        .where((f) => f.chapters.any((ref) => ref.path == source.path))
        .firstOrNull;
    for (final ref in folder?.chapters ?? const <ChapterRef>[]) {
      if (ref == source) continue;
      final chapter = await library.chapterForSearch(ref);
      if (chapter != null && _plays(chapter, kept)) return ref;
    }
    return null;
  }

  /// Whether the chapter on the board, the draft, now plays the line.
  bool _played(KeptFind kept) {
    final chapter = session.chapter;
    return chapter != null && _plays(chapter, kept);
  }

  Future<bool> _trainOpen(List<String> sans, void Function() showTrain) async {
    requests.switchTo(Mode.repertoires);
    showTrain();
    if (await trainer.trainLineThrough(sans)) return true;
    requests.say('Could not start training that line.');
    return false;
  }

  static bool _sameRoot(Chapter chapter, KeptFind kept) =>
      chapter.tree.rootFen.position == kept.rootFen.position;

  static bool _plays(Chapter chapter, KeptFind kept) =>
      chapter.side == kept.side &&
      _sameRoot(chapter, kept) &&
      pathOfSans(chapter.tree, kept.find.sans) != null;
}
