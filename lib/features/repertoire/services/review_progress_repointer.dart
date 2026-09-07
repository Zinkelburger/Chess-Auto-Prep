/// Keeping training progress attached to a line that changed chapter.
///
/// Review schedules and per-move progress carry `repertoireId` = the path of
/// the chapter file the line was in, so any edit that moves a line to another
/// file — a split, a drag into another chapter — reads afterwards as one
/// line deleted and a new one added, and every due date is lost. This
/// re-points those records at the file the line landed in.
///
/// Pinning the id is the other half (see [pinLineId]): a line without an id
/// header gets the position-based fallback id, which a move would change.
library;

import '../../../models/repertoire_move_progress.dart';
import '../../../models/repertoire_review_entry.dart';
import '../../../services/repertoire_line_ids.dart';
import '../../../services/repertoire_review_service.dart';

class ReviewProgressRepointer {
  ReviewProgressRepointer({RepertoireReviewService? review})
    : _review = review ?? RepertoireReviewService();

  final RepertoireReviewService _review;

  static final _idHeader = RegExp(
    '^\\[(${RepertoireLineIds.headerKeys.join('|')})\\s+"',
    multiLine: true,
    caseSensitive: false,
  );

  static final _eventHeader = RegExp(r'^\[Event .*\]$', multiLine: true);

  /// [gameText] with `[LineID "id"]` written in, unless it already carries an
  /// id header of its own. The fallback id encodes the game's position in
  /// its file, so a move would rename the line and orphan its progress;
  /// once the id is a header it travels with the game.
  static String pinLineId(String gameText, String id) {
    if (_idHeader.hasMatch(gameText)) return gameText;
    final header = '[LineID "$id"]';
    final event = _eventHeader.firstMatch(gameText);
    return event == null
        ? '$header\n$gameText'
        : gameText.replaceRange(event.end, event.end, '\n$header');
  }

  /// Re-points the review schedule and per-move progress of every line id in
  /// [movedIdsByPath] from chapter [from] to the path it is keyed under.
  Future<void> repoint({
    required String from,
    required Map<String, Set<String>> movedIdsByPath,
  }) async {
    final newPathById = <String, String>{
      for (final entry in movedIdsByPath.entries)
        for (final id in entry.value) id: entry.key,
    };
    if (newPathById.isEmpty) return;

    final entries = await _review.loadAll();
    var changed = false;
    final rewritten = <RepertoireReviewEntry>[];
    for (final e in entries) {
      final to = e.repertoireId == from ? newPathById[e.lineId] : null;
      if (to == null) {
        rewritten.add(e);
        continue;
      }
      changed = true;
      rewritten.add(
        RepertoireReviewEntry(
          repertoireId: to,
          lineId: e.lineId,
          lineName: e.lineName,
          difficulty: e.difficulty,
          intervalDays: e.intervalDays,
          dueDateUtc: e.dueDateUtc,
          lastRating: e.lastRating,
          lastReviewedUtc: e.lastReviewedUtc,
          passCount: e.passCount,
          failCount: e.failCount,
        ),
      );
    }
    if (changed) await _review.saveAll(rewritten);

    final progress = await _review.loadMoveProgress();
    var progressChanged = false;
    final movedProgress = <RepertoireMoveProgress>[];
    for (final mp in progress) {
      final to = mp.repertoireId == from ? newPathById[mp.lineId] : null;
      if (to == null) {
        movedProgress.add(mp);
        continue;
      }
      progressChanged = true;
      movedProgress.add(
        RepertoireMoveProgress(
          repertoireId: to,
          lineId: mp.lineId,
          moveIndex: mp.moveIndex,
          correctStreak: mp.correctStreak,
          learned: mp.learned,
        ),
      );
    }
    if (progressChanged) await _review.saveMoveProgress(movedProgress);
  }
}
