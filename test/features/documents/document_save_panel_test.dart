import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/features/documents/controllers/document_save_session.dart';
import 'package:chess_auto_prep/features/documents/models/document_save_state.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_creation.dart';
import 'package:chess_auto_prep/features/repertoires/widgets/repertoire_creation_screen.dart';

import '../../support/document_save_host.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import '../../support/scripted_document_store.dart';

void main() {
  testWidgets(
    'conflict actions preserve draft, return editor focus and save a copy exclusively',
    (tester) async {
      final store = Store();
      final session = DocumentSaveSession.opened(store, store.current);
      addTearDown(session.dispose);
      var destination = '/copy.pgn';
      await tester.pumpWidget(
        DocumentSaveHost(
          session: session,
          chooseCopyDestination: (_) async => destination,
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('document-draft')),
        'my draft',
      );
      store.current = snapshot('external', revision: '2');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('document-save')));
      await tester.pumpAndSettle();
      expect(session.state.phase, DocumentSavePhase.conflict);
      await tester.tap(find.text('Inspect current file'));
      await tester.pumpAndSettle();
      expect(find.text('external'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(session.state.content, 'my draft');
      expect(session.state.baseline!.content, 'original');
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('document-draft')))
            .focusNode!
            .hasFocus,
        isTrue,
      );
      store.onCreate = (_, _) async => const PgnNameCollision();
      await tester.tap(find.byKey(const ValueKey('document-save-copy')));
      await tester.pumpAndSettle();
      expect(session.state.content, 'my draft');
      expect(session.state.phase, DocumentSavePhase.collision);
      destination = '/new-copy.pgn';
      store.onCreate = null;
      await tester.tap(find.byKey(const ValueKey('document-save-copy')));
      await tester.pumpAndSettle();
      expect(find.text('Saved'), findsOneWidget);
      expect(session.state.path, destination);
      expect(store.saves, hasLength(1));
    },
  );

  testWidgets(
    'cancelled destination makes no write and reload exposes retained draft',
    (tester) async {
      final store = Store();
      final session = DocumentSaveSession.opened(store, store.current)
        ..edit('my draft');
      addTearDown(session.dispose);
      store.current = snapshot('external', revision: '2');
      await session.save();
      await tester.pumpWidget(
        DocumentSaveHost(
          session: session,
          chooseCopyDestination: (_) async => null,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('document-save-copy')));
      await tester.pumpAndSettle();
      expect(store.creates, isEmpty);
      await tester.tap(find.text('Reload and keep draft'));
      await tester.pumpAndSettle();
      expect(session.state.content, 'external');
      await tester.tap(find.text('Restore retained draft'));
      await tester.pumpAndSettle();
      expect(session.state.content, 'my draft');
      expect(session.state.dirty, isTrue);
      expect(store.saves, hasLength(1));
    },
  );

  for (final light in [false, true]) {
    testWidgets(
      'uncertain status at 200 percent wraps in narrow ${light ? 'light' : 'dark'} host',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(430, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final store = Store();
        final session = DocumentSaveSession.opened(store, store.current)
          ..edit('draft');
        addTearDown(session.dispose);
        store.onSave = (before, _) async => PgnWriteUncertain(
          error: StateError('flush'),
          before: before,
          observed: null,
        );
        await session.save();
        await tester.pumpWidget(
          DocumentSaveHost(
            session: session,
            chooseCopyDestination: (_) async => null,
            light: light,
            scale: 2,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FilledButton>(find.byKey(const ValueKey('document-save')))
              .onPressed,
          isNull,
        );
        expect(find.text('Save a copy…'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'creation collision offers name focus without discarding PGN or side',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.dark(),
          home: RepertoireCreationScreen(
            create: (_) async =>
                throw const RepertoireExistsException('Existing'),
          ),
        ),
      );
      final name = find.byKey(const ValueKey('repertoire-create-name'));
      final pgn = find.byKey(const ValueKey('repertoire-create-pgn'));
      await tester.enterText(name, 'Existing');
      await tester.enterText(pgn, '1. d4 d5 *');
      await tester.tap(find.text('Black'));
      await tester.tap(find.widgetWithText(FilledButton, 'Create repertoire'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose another name'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextFormField>(name);
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: name, matching: find.byType(TextField)),
            )
            .focusNode!
            .hasFocus,
        isTrue,
      );
      expect(
        field.controller!.selection,
        const TextSelection(baseOffset: 0, extentOffset: 8),
      );
      expect(tester.widget<TextField>(pgn).controller!.text, '1. d4 d5 *');
      expect(
        tester
            .widget<SegmentedButton<String>>(
              find.byType(SegmentedButton<String>),
            )
            .selected,
        {'Black'},
      );
      expect(tester.takeException(), isNull);
    },
  );
}
