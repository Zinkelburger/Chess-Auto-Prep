import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chess_auto_prep/core/pgn_viewer_controller.dart';
import 'package:chess_auto_prep/core/pgn/pgn_viewer_handle.dart';
import 'package:chess_auto_prep/core/pgn/viewer_session_store.dart';
import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:chess_auto_prep/features/games/models/game_view_preferences.dart';
import 'package:chess_auto_prep/services/game_analysis_controller.dart';
import 'package:chess_auto_prep/services/pgn_parsing_service.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';

class _Handle implements PgnViewerHandle {
  @override
  int mainLineIndex = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Analysis extends GameAnalysisController {
  @override
  Future<bool> tryLoadFromPgn(String pgnText) async => false;
  @override
  void cancel() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late String path;
  final controllers = <PgnViewerController>[];
  PgnViewerController make([_Handle? handle]) {
    final controller = PgnViewerController(
      pgnWidgetController: handle ?? _Handle(),
      analysisController: _Analysis(),
    );
    controllers.add(controller);
    return controller;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    StorageFactory.instanceForTest = IOStorageService();
    dir = await Directory.systemTemp.createTemp('viewer-session-test-');
    path = p.join(dir.path, 'fischer.pgn');
    await File(path).writeAsString(
      '; Collection banner\n\n${List.generate(40, (i) => '[Event "Game $i"]\n[White "Fischer, Robert"]\n[Black "Opponent $i"]\n[Date "${1959 + i}.??.??"]\n\n1. e4 c5 2. Nf3 d6 3. d4 cxd4 *').join('\n\n')}\n',
    );
  });

  tearDown(() async {
    for (final controller in controllers) {
      await controller.flushPendingMetadata();
      await controller.saveSession();
      controller.dispose();
    }
    controllers.clear();
    StorageFactory.instanceForTest = null;
    await dir.delete(recursive: true);
  });

  test(
    'OR and multiple positions survive reopen, chip removal and presets',
    () async {
      final first = make();
      await first.loadFile(path);
      const config = SliceConfig(
        matchAny: true,
        positionInput: '1. c4',
        additionalPositions: ['1. e4', '1. d4'],
        headerFilters: [
          HeaderFilterConfig(
            field: 'Event',
            mode: MatchMode.exact,
            value: 'Game 0',
          ),
        ],
      );
      await first.recomputeAndApplyConfig(config);
      await first.persistSliceConfig(config);
      final reopened = make();
      await reopened.loadFile(path);
      expect(reopened.filteredGames, hasLength(40));
      expect(reopened.activeSliceConfig.toJsonString(), config.toJsonString());
      await reopened.removeSliceChip(1);
      expect(reopened.filteredGames, hasLength(1));
      expect(reopened.activeSliceConfig.additionalPositions, ['1. d4']);
      expect(reopened.activeSliceConfig.matchAny, isTrue);
      await reopened.applySlicePreset(
        const HeaderFilterConfig(
          field: 'Black',
          mode: MatchMode.exact,
          value: 'Opponent 1',
        ),
      );
      expect(reopened.filteredGames, hasLength(2));
      expect(reopened.activeSliceConfig.additionalPositions, ['1. d4']);
      expect(reopened.activeSliceConfig.matchAny, isTrue);
    },
  );

  test(
    'opening detection never writes staged edits in manual-save mode',
    () async {
      final c = make()..setAutoSave(false);
      final original = await File(path).readAsString();
      await c.loadFile(path);
      expect(await File(path).readAsString(), original);
      expect(c.hasUnsavedChanges, isTrue);
      expect(c.allGames.first.headers['ECO'], isNotEmpty);
      expect(await c.saveChanges(), isTrue);
      expect(await File(path).readAsString(), contains('[ECO "'));
    },
  );

  test(
    'restart restores file, date slice, game 37 and move; reordered files keep identity',
    () async {
      final handle = _Handle();
      final first = make(handle);
      await first.loadFile(path);
      expect(first.errorMessage, isNull);
      const config = SliceConfig(
        headerFilters: [
          HeaderFilterConfig(
            field: 'Date',
            mode: MatchMode.after,
            value: '1960',
          ),
        ],
      );
      await first.recomputeAndApplyConfig(config);
      await first.persistSliceConfig(config);
      first.goToGame(36);
      handle.mainLineIndex = 4;
      first.rememberReadingPosition();
      await first.saveSession();
      final selected =
          first.filteredGames[first.currentGameIndex].headers['Event'];

      final reopened = make();
      await reopened.restoreLastSession();
      expect(reopened.filePath, path);
      expect(reopened.currentGameIndex, 36);
      expect(reopened.filteredGames, hasLength(39));
      expect(reopened.activeSliceConfig.toJsonString(), config.toJsonString());
      expect(reopened.resumePlyFor(reopened.filteredGames[36]), 4);

      reopened.setSortMode(GameSortMode.dateDesc);
      final index = reopened.filteredGames.indexWhere(
        (g) => g.headers['Event'] == selected,
      );
      reopened.goToGame(index);
      await reopened.saveSession();
      final third = make();
      await third.loadFile(path);
      expect(third.sortMode, GameSortMode.dateDesc);
      expect(
        third.filteredGames[third.currentGameIndex].headers['Event'],
        selected,
      );

      // Insertions/reordering must not restore an unrelated game at the old index.
      final games = parseMultiGamePgn(await File(path).readAsString());
      await File(
        path,
      ).writeAsString(games.reversed.map((g) => g.pgnText).join('\n\n'));
      final fourth = make();
      await fourth.loadFile(path);
      expect(
        fourth.filteredGames[fourth.currentGameIndex].headers['Event'],
        selected,
      );
    },
  );

  test(
    'ECO tags are saved for all games; ECO slice restores; off prevents writes',
    () async {
      final first = make();
      await first.loadFile(path);
      final text = await File(path).readAsString();
      expect(text, startsWith('; Collection banner'));
      expect(
        first.allGames.every(
          (g) => g.headers['ECO'] != null && g.headers['Opening'] != null,
        ),
        isTrue,
      );
      expect(
        parseMultiGamePgn(text).every((g) => g.headers['ECO'] != null),
        isTrue,
      );
      final eco = first.allGames.first.headers['ECO']!;
      final config = SliceConfig(
        headerFilters: [
          HeaderFilterConfig(field: 'ECO', mode: MatchMode.exact, value: eco),
        ],
      );
      await first.recomputeAndApplyConfig(config);
      await first.persistSliceConfig(config);
      final second = make();
      await second.loadFile(path);
      expect(second.activeSliceConfig.toJsonString(), config.toJsonString());
      expect(second.filteredGames, hasLength(40));

      await const GameViewPreferences(autoDetectOpenings: false).save();
      final other = p.join(dir.path, 'no-tags.pgn');
      const raw = '[White "A"]\n[Black "B"]\n\n1. e4 e5 *';
      await File(other).writeAsString(raw);
      final off = make();
      await off.loadFile(other);
      expect(off.autoDetectOpenings, isFalse);
      expect(off.allGames.single.headers['ECO'], isNull);
      expect(await File(other).readAsString(), raw);
    },
  );

  test(
    'explicit handoff skips saved place; closing clears auto-reopen only',
    () async {
      final first = make();
      await first.loadFile(path);
      first.goToGame(10);
      await first.saveSession();
      final handoff = make();
      await handoff.loadFile(path, restoreSavedSlice: false);
      expect(handoff.currentGameIndex, 0);
      handoff.closeFile();
      await ViewerSessionStore().load(path); // allow queued preferences IO
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final fresh = make();
      await fresh.restoreLastSession();
      expect(fresh.filePath, isNull);
      expect(await ViewerSessionStore().load(path), isNotNull);
    },
  );
}
