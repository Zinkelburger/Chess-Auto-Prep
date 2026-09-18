import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/features/documents/repositories/stored_game_repository.dart';
import 'package:provider/provider.dart';
import 'package:chess_auto_prep/widgets/pgn_viewer_widget.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_annotation_panel.dart';

class DelayedGameArchive implements StoredGameRepository {
  final reads = <String, Completer<String?>>{};
  @override
  Future<String?> findById(String id) =>
      (reads[id] = Completer<String?>()).future;
}

/// The same production reader scenarios run with widget and Linux bindings.
void viewerLoadingScenarios() {
  testWidgets('changing only the initial FEN replaces the game position', (
    tester,
  ) async {
    final control = PgnViewerWidgetController();
    Future<void> show(String fen) => tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PgnViewerWidget(
            controller: control,
            pgnText: '[SetUp "1"]\n[FEN "$fen"]\n\n*',
          ),
        ),
      ),
    );
    const first = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    const second = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
    await show(first);
    await tester.pumpAndSettle();
    expect(control.currentFen, first);
    await show(second);
    await tester.pumpAndSettle();
    expect(control.currentFen, second);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'a newer empty selection keeps its error after a late successful read',
    (tester) async {
      final archive = DelayedGameArchive();
      var loaded = 0;
      Future<void> show(String? id) => tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PgnViewerWidget(
              storedGames: archive,
              gameId: id,
              onGameLoaded: () => loaded++,
            ),
          ),
        ),
      );
      await show('old');
      await show(null);
      await tester.pumpAndSettle();
      expect(find.text('No game ID or PGN text provided'), findsOneWidget);
      archive.reads['old']!.complete('1. e4 *');
      await tester.pumpAndSettle();
      expect(find.text('No game ID or PGN text provided'), findsOneWidget);
      expect(loaded, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final lateFailure in [false, true]) {
    testWidgets(
      'new selection survives late archive ${lateFailure ? "failure" : "success"}',
      (tester) async {
        final archive = DelayedGameArchive();
        final control = PgnViewerWidgetController();
        final positions = <String>[];
        var loaded = 0;
        Future<void> show(String id) => tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Provider<StoredGameRepository>.value(
                value: archive,
                child: PgnViewerWidget(
                  gameId: id,
                  controller: control,
                  initialMainLineIndex: 2,
                  onPositionChanged: (p) => positions.add(p.fen),
                  onGameLoaded: () => loaded++,
                ),
              ),
            ),
          ),
        );
        await show('old');
        await show('new');
        archive.reads['new']!.complete('[White "Current"]\n\n1. d4 d5 *');
        await tester.pumpAndSettle();
        expect(control.mainLineMoves, ['d4', 'd5']);
        final fen = control.currentFen;
        final count = positions.length;
        expect(loaded, 1);
        if (lateFailure) {
          archive.reads['old']!.completeError(StateError('late failure'));
        } else {
          archive.reads['old']!.complete('[White "Obsolete"]\n\n1. e4 e5 *');
        }
        await tester.pumpAndSettle();
        expect(control.mainLineMoves, ['d4', 'd5']);
        expect(control.currentFen, fen);
        expect(positions.length, count);
        expect(loaded, 1);
        expect(find.textContaining('Obsolete'), findsNothing);
        expect(find.textContaining('Error loading'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'fallback replacement while reading stays with the latest request',
    (tester) async {
      final archive = DelayedGameArchive();
      final control = PgnViewerWidgetController();
      Future<void> show(String text) => tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PgnViewerWidget(
              storedGames: archive,
              gameId: 'missing',
              pgnText: text,
              controller: control,
            ),
          ),
        ),
      );
      await show('1. e4 *');
      final first = archive.reads['missing']!;
      await show('1. c4 *');
      archive.reads['missing']!.complete(null);
      await tester.pumpAndSettle();
      first.complete(null);
      await tester.pumpAndSettle();
      expect(control.mainLineMoves, ['c4']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('scope replacement revokes the previous archive', (tester) async {
    final old = DelayedGameArchive();
    final current = DelayedGameArchive();
    final control = PgnViewerWidgetController();
    Future<void> show(DelayedGameArchive archive) => tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Provider<StoredGameRepository>.value(
            value: archive,
            child: PgnViewerWidget(gameId: 'same', controller: control),
          ),
        ),
      ),
    );
    await show(old);
    await show(current);
    current.reads['same']!.complete('1. d4 *');
    await tester.pumpAndSettle();
    old.reads['same']!.complete('1. e4 *');
    await tester.pumpAndSettle();
    expect(control.mainLineMoves, ['d4']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unmount during a read emits no callbacks or exceptions', (
    tester,
  ) async {
    final archive = DelayedGameArchive();
    var callbacks = 0;
    final control = PgnViewerWidgetController();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PgnViewerWidget(
            gameId: 'pending',
            storedGames: archive,
            controller: control,
            onPositionChanged: (_) => callbacks++,
            onGameLoaded: () => callbacks++,
          ),
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    archive.reads['pending']!.complete('1. e4 *');
    await tester.pumpAndSettle();
    expect(callbacks, 0);
    expect(control.currentFen, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'replaced handles detach and header-only updates preserve the cursor',
    (tester) async {
      final old = PgnViewerWidgetController();
      final current = PgnViewerWidgetController();
      Future<void> show(PgnViewerWidgetController handle, String name) =>
          tester.pumpWidget(
            MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: PgnViewerWidget(
                  controller: handle,
                  pgnText: '[White "$name"]\n\n1. e4 e5 *',
                ),
              ),
            ),
          );
      await show(old, 'Original');
      await tester.pumpAndSettle();
      old.goToMainLineIndex(1);
      final fen = old.currentFen;
      await show(current, 'Updated');
      await tester.pumpAndSettle();
      expect(old.currentFen, isNull);
      old.goForward();
      expect(current.currentFen, fen);
      expect(find.textContaining('Updated'), findsWidgets);
      current.goForward();
      await tester.pumpAndSettle();
      expect(current.currentFen, isNot(fen));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('old annotation callbacks cannot save into a loading selection', (
    tester,
  ) async {
    final archive = DelayedGameArchive();
    final control = PgnViewerWidgetController();
    final saves = <String>[];
    Future<void> show(String? id) => tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PgnViewerWidget(
            gameId: id,
            storedGames: archive,
            controller: control,
            pgnText: '1. e4 e5 *',
            editMode: true,
            onCommentsChanged: saves.add,
          ),
        ),
      ),
    );
    await show(null);
    await tester.pumpAndSettle();
    control.goToMainLineIndex(1);
    await tester.pumpAndSettle();
    final panel = tester.widget<PgnAnnotationPanel>(
      find.byType(PgnAnnotationPanel),
    );
    await show('next');
    panel.onCommentChanged('Stale note');
    panel.onToggleNag(1);
    expect(saves, isEmpty);
    archive.reads['next']!.complete('1. d4 *');
    await tester.pumpAndSettle();
    expect(control.mainLineMoves, ['d4']);
    expect(saves, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
