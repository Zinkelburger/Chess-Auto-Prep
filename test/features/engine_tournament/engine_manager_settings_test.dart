import 'package:chess_auto_prep/features/engine_tournament/controllers/engine_tournament_controller.dart';
import 'package:chess_auto_prep/features/engine_tournament/models/engine_spec.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/engine_verification.dart';
import 'package:chess_auto_prep/features/engine_tournament/widgets/engine_manager_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Controller extends EngineTournamentController {
  EngineSpec spec = EngineSpec.bundledStockfish;
  @override
  List<EngineSpec> get engines => [spec];
  @override
  Future<void> updateEngine(EngineSpec value) async {
    spec = value;
    notifyListeners();
  }

  @override
  Future<EngineVerification> verifyEngine(EngineSpec spec) async =>
      const EngineVerification(ok: true, message: 'Ready to play.');
}

void main() {
  testWidgets(
    'engine editing and verification stay inline and save the draft',
    (tester) async {
      final controller = _Controller();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EngineManagerBody(controller: controller, embedded: true),
          ),
        ),
      );
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.enterText(
        find.widgetWithText(TextField, 'Name'),
        'My tournament engine',
      );
      await tester.pumpAndSettle();
      FocusManager.instance.primaryFocus?.unfocus();
      expect(controller.spec.name, isNot('My tournament engine'));
      await tester.scrollUntilVisible(
        find.text('Save'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(controller.spec.name, 'My tournament engine');
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('Test engine'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Ready to play.'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
