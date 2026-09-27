import 'package:chess_auto_prep/features/repertoires/widgets/builder_copy_inspection_dialog.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final acknowledge in [false, true]) {
    testWidgets(
      'narrow 200% inspection keeps decision accessible: $acknowledge',
      (tester) async {
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        bool? decision;
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async => decision = await showDialog<bool>(
                    context: context,
                    builder: (_) => BuilderCopyInspectionDialog(
                      destination: '/a/very/long/repertoire/path/chapter.pgn',
                      content: List.filled(
                        100,
                        '[Event "Retained copy"]\n\n1. e4 e5 *',
                      ).join('\n'),
                    ),
                  ),
                  child: const Text('Inspect'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Inspect'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(
          find.text(acknowledge ? 'Copy is present' : 'Keep draft'),
        );
        await tester.pumpAndSettle();
        expect(decision, acknowledge);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
