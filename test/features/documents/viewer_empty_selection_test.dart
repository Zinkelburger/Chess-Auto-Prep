import 'dart:async';

import 'package:chess_auto_prep/chess_core/pgn/pgn_collection.dart';
import 'package:chess_auto_prep/features/documents/controllers/viewer_document_controller.dart';
import 'package:chess_auto_prep/features/documents/models/viewer_collection_load.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_collection_decoder.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_collection_filter.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_collection_repository.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_library_repository.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_viewer_handle.dart';
import 'package:chess_auto_prep/features/documents/repositories/viewer_analysis_port.dart';
import 'package:chess_auto_prep/features/documents/repositories/viewer_opening_repository.dart';
import 'package:chess_auto_prep/features/documents/repositories/viewer_position_index_repository.dart';
import 'package:chess_auto_prep/features/documents/repositories/viewer_preferences_repository.dart';
import 'package:chess_auto_prep/features/documents/repositories/viewer_solitaire_repository.dart';
import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_desktop_fullscreen_port.dart';

// This scenario changes an already decoded, in-memory collection. Any storage,
// worker or preference call would be unexpected; no global resources are used.
class _UnusedPort {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected dependency call: ${invocation.memberName}');
}

class _Documents extends _UnusedPort implements PgnCollectionRepository {}

class _Decoder extends _UnusedPort implements PgnCollectionDecoder {}

class _Filter extends _UnusedPort implements PgnCollectionFilter {}

class _Library extends _UnusedPort implements PgnLibraryRepository {}

class _Preferences extends _UnusedPort implements ViewerPreferencesRepository {}

class _Openings extends _UnusedPort implements ViewerOpeningRepository {}

class _Index extends _UnusedPort implements ViewerPositionIndexRepository {}

class _Solitaire extends _UnusedPort implements ViewerSolitaireRepository {}

class _Handle extends _UnusedPort implements PgnViewerHandle {
  @override
  int get mainLineIndex => 1;
}

class _DelayedAnalysis implements ViewerAnalysisPort {
  final loaded = Completer<bool>();
  final cachedEvals = <int>[];
  int cancellations = 0;
  int enrichments = 0;

  @override
  void cancel() => cancellations++;

  @override
  void clearEvals() => cachedEvals.clear();

  @override
  Future<bool> tryLoadFromPgn(String pgnText) => loaded.future;

  @override
  Future<void> fillMissingBestLines(
    String pgnText, {
    required void Function(String movetext) onAnnotatedMovetext,
  }) async {
    enrichments++;
    onAnnotatedMovetext('1. e4 {stale enrichment} e5 *');
  }
}

void main() {
  test(
    'empty filter cancels reading work and rejects late cached analysis',
    () async {
      final analysis = _DelayedAnalysis();
      var focusRequests = 0;
      final document = ViewerDocumentController(
        window: FakeDesktopFullscreenPort(),
        positionIndex: _Index(),
        openings: _Openings(),
        solitaireRepository: _Solitaire(),
        collectionRepository: _Documents(),
        collectionDecoder: _Decoder(),
        collectionFilter: _Filter(),
        library: _Library(),
        preferences: _Preferences(),
        pgnWidgetController: _Handle(),
        analysisController: analysis,
        onReclaimFocus: () => focusRequests++,
      );
      addTearDown(document.dispose);
      const pgn = '[Event "Outgoing"]\n\n1. e4 e5 *';
      document.adoptDecodedCollection(
        DecodedPgnCollection(parseMultiGamePgn(pgn), ''),
      );
      final outgoing = document.collection.games.single;
      final loading = document.reading.loadCurrentGame();
      analysis.cachedEvals.add(35);
      const priorFen =
          'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
      document.reading.onPositionChanged(
        Chess.fromSetup(Setup.parseFen(priorFen)),
      );
      document.reading.pgnInitialFen = priorFen;
      document.reading.playback.start();
      expect(document.reading.playback.isPlaying, isTrue);
      final cancellations = analysis.cancellations;
      var notifications = 0;
      document.changes.addListener(() => notifications++);

      document.applySlice(
        [],
        const SliceConfig(
          headerFilters: [
            HeaderFilterConfig(
              field: 'Event',
              mode: MatchMode.contains,
              value: 'Missing',
            ),
          ],
        ),
      );

      expect(document.collection.visibleGames, isEmpty);
      expect(analysis.cancellations, cancellations + 1);
      expect(analysis.cachedEvals, isEmpty);
      expect(document.reading.playback.isPlaying, isFalse);
      expect(document.reading.currentPosition.fen, Chess.initial.fen);
      expect(document.reading.pgnInitialFen, isNull);
      final emptyNotifications = notifications;
      analysis.loaded.complete(true);
      await loading;
      await Future<void>.value();

      expect(notifications, emptyNotifications);
      expect(focusRequests, 0);
      expect(analysis.enrichments, 0);
      expect(outgoing.pgnText, pgn);
      expect(document.editor.hasUnsavedChanges, isFalse);
      expect(document.collection.visibleGames, isEmpty);
    },
  );
}
