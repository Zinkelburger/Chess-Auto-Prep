import 'package:chess_auto_prep/features/training/models/training_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../support/training_settings.dart';
import 'package:chess_auto_prep/app/app_dependencies.dart';
import 'package:chess_auto_prep/features/training/controllers/training_settings_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'all training routes share the same application settings writer',
    (tester) async {
      final seen = <TrainingSettingsController>[];
      Widget consumer() => Builder(
        builder: (context) {
          seen.add(context.read<TrainingSettingsController>());
          return const SizedBox();
        },
      );
      await tester.pumpWidget(
        AppDependencies(child: Column(children: [consumer(), consumer()])),
      );
      expect(identical(seen[0], seen[1]), isTrue);
      final original = seen.first;
      await tester.pumpWidget(AppDependencies(child: consumer()));
      expect(identical(original, seen.last), isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'app loads replacement settings and leaves injected owners alive',
    (tester) async {
      final firstStore = MemoryTrainingSettings(
        TrainingSettings(moveSpeedMs: 350),
      );
      final secondStore = MemoryTrainingSettings(
        TrainingSettings(moveSpeedMs: 900),
      );
      final first = TrainingSettingsController(firstStore);
      final second = TrainingSettingsController(secondStore);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      Widget host(TrainingSettingsController owner) => AppDependencies(
        trainingSettings: owner,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (context) {
              final settings = context.watch<TrainingSettingsController>();
              return Text(
                '${settings.state.committed?.toSettings().moveSpeedMs}',
              );
            },
          ),
        ),
      );
      await tester.pumpWidget(host(first));
      await tester.pumpAndSettle();
      expect(firstStore.reads, 1);
      expect(find.text('350'), findsOneWidget);
      await tester.pumpWidget(host(second));
      await tester.pumpAndSettle();
      expect(secondStore.reads, 1);
      expect(find.text('900'), findsOneWidget);
      await first.edit({'trainer_move_speed_ms': 600});
      await tester.pump();
      expect(find.text('900'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await second.edit({'trainer_move_speed_ms': 750});
      expect(second.committed.toSettings().moveSpeedMs, 750);
      expect(tester.takeException(), isNull);
    },
  );
}
