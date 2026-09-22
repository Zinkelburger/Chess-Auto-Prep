import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_annotation_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'compact comments expand via focus shortcut and retain edits when collapsed',
    (tester) async {
      String? comment;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,

          home: Scaffold(
            body: PgnAnnotationPanel(
              compact: true,
              targetKey: 'move-1',
              moveLabel: '1. e4',
              nags: const [],
              comment: '',
              commentDebounce: Duration.zero,
              onToggleNag: (_) {},
              onCommentChanged: (text) => comment = text,
            ),
          ),
        ),
      );
      expect(find.byType(TextField), findsNothing);
      expect(PgnAnnotationPanel.focusActive(), isTrue);
      await tester.pump();
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Control the centre.');
      await tester.pump();
      expect(comment, 'Control the centre.');
      await tester.tap(find.byTooltip('Collapse comment'));
      await tester.pump();
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byTooltip('Edit comment'));
      await tester.pump();
      expect(find.text('Control the centre.'), findsOneWidget);
    },
  );
}
