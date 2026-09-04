/// Unit-level half of the eval-source round trip.
///
/// `generation_config_form_roundtrip_test.dart` proves a config survives the
/// whole form; this pins the rules [EvalSourcesController] applies on its own
/// — the depth floor's three cases, the clamps, and the cdb-direct gate —
/// which now have a home outside a widget's [State] to be tested in.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/models/eval_database_settings.dart';
import 'package:chess_auto_prep/services/generation/generation_config.dart';
import 'package:chess_auto_prep/widgets/generation/eval_sources_controller.dart';

const _seedFen = kStandardStartFen;
const _base = TreeBuildConfig(startFen: _seedFen, playAsWhite: true);

TreeBuildConfig _readBack(
  EvalSourcesController controller, {
  bool cdbDirectAvailable = true,
  int engineEvalDepth = 20,
}) => controller.applyTo(
  _base,
  databases: EvalDatabaseSettings.instance,
  cdbDirectAvailable: cdbDirectAvailable,
  engineEvalDepth: engineEvalDepth,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late EvalSourcesController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = EvalSourcesController();
  });
  tearDown(() => controller.dispose());

  group('applyConfig ↔ applyTo', () {
    test('every field the section owns survives the round trip', () {
      const seed = TreeBuildConfig(
        startFen: _seedFen,
        playAsWhite: true,
        enableLocalChessDb: true,
        localChessDbPath: '/tmp/chessdb.db',
        enableChessDbApi: false,
        chessDbApiDailyQuota: 1234,
        chessDbApiConcurrency: 7,
        enableExtEvalSubtreeSkip: false,
        minAcceptableEvalDepth: 18,
      );

      controller.applyConfig(seed);
      final back = _readBack(controller);

      expect(back.enableLocalChessDb, isTrue);
      expect(back.localChessDbPath, '/tmp/chessdb.db');
      expect(back.enableChessDbApi, isFalse);
      expect(back.chessDbApiDailyQuota, 1234);
      expect(back.chessDbApiConcurrency, 7);
      expect(back.enableExtEvalSubtreeSkip, isFalse);
      expect(back.minAcceptableEvalDepth, 18);
    });

    test('the fields the section does not own are left alone', () {
      controller.applyConfig(_base);
      final back = _readBack(controller);

      expect(back.startFen, _seedFen);
      expect(back.evalDepth, _base.evalDepth);
    });
  });

  group('the eval-depth floor', () {
    test('an empty field means "no floor", not "the engine depth"', () {
      controller.applyConfig(
        const TreeBuildConfig(
          startFen: _seedFen,
          playAsWhite: true,
          minAcceptableEvalDepth: 0,
        ),
      );

      expect(controller.minEvalDepthField.text, isEmpty);
      expect(
        _readBack(controller, engineEvalDepth: 26).minAcceptableEvalDepth,
        0,
      );
    });

    test('a typed number is taken as written', () {
      controller.minEvalDepthField.text = '14';
      expect(
        _readBack(controller, engineEvalDepth: 26).minAcceptableEvalDepth,
        14,
      );
    });

    test('an unparseable entry asks for what the engine would produce', () {
      controller.minEvalDepthField.text = 'deep';
      expect(
        _readBack(controller, engineEvalDepth: 26).minAcceptableEvalDepth,
        26,
        reason: 'falling back to 0 would silently accept every shallow hit',
      );
    });
  });

  group('the API budget fields', () {
    test('are clamped to what the provider accepts', () {
      controller.dailyQuotaField.text = '999999';
      controller.concurrencyField.text = '0';

      final back = _readBack(controller);
      expect(back.chessDbApiDailyQuota, 50000);
      expect(back.chessDbApiConcurrency, 1);
    });

    test('fall back to the defaults when cleared', () {
      controller.dailyQuotaField.clear();
      controller.concurrencyField.clear();

      final back = _readBack(controller);
      expect(back.chessDbApiDailyQuota, 5000);
      expect(back.chessDbApiConcurrency, 2);
    });
  });

  group('the cdb-direct gate', () {
    test('nothing is written when the install is not there', () async {
      await EvalDatabaseSettings.instance.setEnableCdbDirect(true);
      await EvalDatabaseSettings.instance.setCdbDirectPath('/opt/cdb');
      await EvalDatabaseSettings.instance.setCdbDirectReadAhead(true);

      final back = _readBack(controller, cdbDirectAvailable: false);

      expect(back.enableCdbDirect, isFalse);
      expect(back.cdbDirectPath, isEmpty);
      expect(back.cdbDirectReadAhead, isFalse);
    });

    test('app settings win when it is', () async {
      await EvalDatabaseSettings.instance.setEnableCdbDirect(true);
      await EvalDatabaseSettings.instance.setCdbDirectPath('/opt/cdb');

      final back = _readBack(controller, cdbDirectAvailable: true);

      expect(back.enableCdbDirect, isTrue);
      expect(back.cdbDirectPath, '/opt/cdb');
    });
  });

  group('the Lichess store gate', () {
    // These two fields have no control in the section — they are read
    // straight off app settings — and for a while nothing read them at all,
    // so every build the form started had the Lichess step switched off no
    // matter what had been downloaded.
    test('app settings reach the config', () async {
      await EvalDatabaseSettings.instance.setEnableLichessEvals(true);
      await EvalDatabaseSettings.instance.setLichessEvalsPath('/data/lichess');

      final back = _readBack(controller);

      expect(back.enableLichessEvals, isTrue);
      expect(back.lichessEvalsPath, '/data/lichess');
    });

    test('the switch alone is not enough without a path', () async {
      await EvalDatabaseSettings.instance.setEnableLichessEvals(true);
      await EvalDatabaseSettings.instance.setLichessEvalsPath('');

      final back = _readBack(controller);

      expect(
        back.enableLichessEvals,
        isFalse,
        reason: 'the provider would open a directory named \'\'',
      );
    });

    test('a path alone does not switch it on', () async {
      await EvalDatabaseSettings.instance.setEnableLichessEvals(false);
      await EvalDatabaseSettings.instance.setLichessEvalsPath('/data/lichess');

      expect(_readBack(controller).enableLichessEvals, isFalse);
    });
  });

  group('the local ChessDB picker', () {
    test('a valid file turns the source on and marks the path good', () {
      controller.setLocalChessDbFile('/tmp/slice.db', valid: true);

      expect(controller.enableLocalChessDb, isTrue);
      expect(controller.localChessDbFileValid, isTrue);
      expect(_readBack(controller).localChessDbPath, '/tmp/slice.db');
    });

    test('an invalid file is recorded but enables nothing', () {
      controller.setLocalChessDbFile('/tmp/notes.db', valid: false);

      expect(controller.enableLocalChessDb, isFalse);
      expect(controller.localChessDbFileValid, isFalse);
    });

    test('clearing forgets both the path and its verdict', () {
      controller.setLocalChessDbFile('/tmp/slice.db', valid: true);
      controller.clearLocalChessDbFile();

      expect(controller.localChessDbPath, isEmpty);
      expect(controller.localChessDbFileValid, isNull);
    });
  });

  test('every setter notifies exactly once, and only on a real change', () {
    var notifications = 0;
    controller.addListener(() => notifications++);

    controller.enableChessDbApi = !controller.enableChessDbApi;
    expect(notifications, 1);

    controller.enableChessDbApi = controller.enableChessDbApi;
    expect(
      notifications,
      1,
      reason: 'assigning the same value is not a change',
    );
  });
}
