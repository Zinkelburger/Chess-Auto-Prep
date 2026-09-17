import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:chess_auto_prep/app/app_dependencies.dart';
import 'package:chess_auto_prep/services/game_store/game_store.dart';
import 'package:chess_auto_prep/services/game_store/game_store_service.dart';
import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';
import '../test/support/viewer_loading_scenarios.dart';
import '../test/support/viewer_annotation_scenarios.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  viewerLoadingScenarios();
  viewerAnnotationScenarios();
  testWidgets(
    'app wiring loads the full archived game before its solution fallback',
    (tester) async {
      final store = await GameStoreService.instance.open();
      final id = 'viewer-native-${DateTime.now().microsecondsSinceEpoch}';
      store.importPgn(
        '[Event "Native archive"]\n[GameId "$id"]\n[White "Archive"]\n\n1. d4 d5 2. c4 *',
        collection: GameCollections.tactics,
      );
      final control = PgnViewerWidgetController();
      await tester.pumpWidget(
        AppDependencies(
          child: MaterialApp(
            home: Scaffold(
              body: PgnViewerWidget(
                gameId: id,
                pgnText: '1. e4 *',
                controller: control,
                initialMainLineIndex: 2,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(control.mainLineMoves, ['d4', 'd5', 'c4']);
      expect(control.currentFen, contains('3p4/3P4'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      GameStoreService.instance.close();
    },
  );
}
