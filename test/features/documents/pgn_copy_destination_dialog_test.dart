import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/features/documents/widgets/pgn_copy_destination_dialog.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';

void main() {
  testWidgets(
    'validates paths, retains input after picker failure, and only returns a destination',
    (tester) async {
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                selected = await showPgnCopyDestinationDialog(
                  context,
                  initialDirectory: '/library',
                  initialName: 'games.pgn',
                  pickDirectory: (_) async => throw StateError('unavailable'),
                );
              },
              child: const Text('Choose'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('pgn-copy-name')),
        '../source',
      );
      await tester.tap(find.byKey(const ValueKey('pgn-copy-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('Enter a file name without folders.'), findsOneWidget);
      expect(selected, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('pgn-copy-name')),
        'new copy',
      );
      await tester.tap(find.byTooltip('Browse folders'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('The folder picker could not open'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('pgn-copy-directory')),
        'relative',
      );
      await tester.tap(find.byKey(const ValueKey('pgn-copy-confirm')));
      await tester.pumpAndSettle();
      expect(find.text('Enter an absolute folder path.'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('pgn-copy-directory')),
        '/chosen',
      );
      await tester.tap(find.byKey(const ValueKey('pgn-copy-confirm')));
      await tester.pumpAndSettle();
      expect(selected, '/chosen/new copy.pgn');
    },
  );
}
