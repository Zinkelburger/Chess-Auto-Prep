import 'package:chess_auto_prep/app/app_dependencies.dart';
import 'package:chess_auto_prep/features/training/repositories/training_settings_repository.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets(
    'all training routes share the same application settings writer',
    (tester) async {
      final seen = <TrainingSettingsRepository>[];
      Widget consumer() => Builder(
        builder: (context) {
          seen.add(context.read<TrainingSettingsRepository>());
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
}
