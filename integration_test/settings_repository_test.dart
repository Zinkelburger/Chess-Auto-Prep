import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:chess_auto_prep/infrastructure/settings/fresh_desktop_preferences_store.dart';

import 'package:chess_auto_prep/features/games/services/my_repertoire_settings.dart';
import 'package:chess_auto_prep/features/games/widgets/my_repertoires_panel.dart';
import 'package:chess_auto_prep/features/settings/models/repertoire_books.dart';
import 'package:chess_auto_prep/features/settings/models/settings_state.dart';
import 'package:chess_auto_prep/infrastructure/settings/shared_preferences_app_settings_repository.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

class _FailOnce implements RepertoireBooksPreferences {
  final delegate = SharedPreferencesRepertoireBooks();
  bool failNextWrite = false;
  @override
  Future<RepertoireBooks> read() => delegate.read();
  @override
  Future<void> writeSide(BookSide side, List<String> paths) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('Injected preference failure');
    }
    await delegate.writeSide(side, paths);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  installFreshDesktopPreferencesStore();
  testWidgets(
    'real read-only preference file never confirms cached failed choices',
    (tester) async {
      if (!Platform.isLinux) return;
      final owner = SharedPreferencesAppSettingsRepository();
      final books = owner.repertoireBooks;
      await books.setPaths(BookSide.white, ['/confirmed']);
      final file = File(
        p.join(
          (await getApplicationSupportDirectory()).path,
          'shared_preferences.json',
        ),
      );
      final before = await file.readAsString();
      await Process.run('chmod', ['400', file.path]);
      try {
        await expectLater(
          books.addPath(BookSide.white, '/pending'),
          throwsStateError,
        );
        expect(books.state.committed!.white, ['/confirmed']);
        expect(books.state.draft!.white, ['/confirmed', '/pending']);
        expect(await file.readAsString(), before);
      } finally {
        await Process.run('chmod', ['600', file.path]);
      }
      await books.retry();
      expect(books.state.committed!.white, ['/confirmed', '/pending']);
      final stored =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(stored['flutter.my_repertoire_white_paths'], [
        '/confirmed',
        '/pending',
      ]);
      final restarted = SharedPreferencesAppSettingsRepository();
      await restarted.repertoireBooks.ensureLoaded();
      expect(restarted.repertoireBooks.state.committed!.white, [
        '/confirmed',
        '/pending',
      ]);
    },
  );
  testWidgets(
    'failed book edit stays visible, retries and survives a fresh owner',
    (tester) async {
      final folder = Directory(
        p.join(
          (await AppPaths.repertoiresDirectory(create: true)).path,
          'Settings ${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      await folder.create();
      await File(
        p.join(folder.path, 'Main.pgn'),
      ).writeAsString('// Color: White\n1. e4 e5 *');
      final preferences = _FailOnce();
      final owner = SharedPreferencesAppSettingsRepository(books: preferences);
      final books = owner.repertoireBooks;
      await books.setPaths(BookSide.white, [folder.path]);
      await books.setPaths(BookSide.black, []);
      final legacy = MyRepertoireSettings(repository: books);
      addTearDown(legacy.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 520,
                child: MyRepertoiresPanel(settings: legacy),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      preferences.failNextWrite = true;
      await tester.tap(find.byTooltip('Stop checking games against this book'));
      for (
        var i = 0;
        i < 100 && books.state.phase != SettingsPhase.failed;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      expect(find.text(p.basename(folder.path)), findsOneWidget);
      expect(find.text('Retry book selections'), findsOneWidget);
      expect((await preferences.read()).white, [folder.path]);
      await tester.tap(find.text('Retry book selections'));
      for (
        var i = 0;
        i < 100 && books.state.phase != SettingsPhase.ready;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      expect(find.text('Retry book selections'), findsNothing);
      expect(find.text(p.basename(folder.path)), findsNothing);
      final restarted = SharedPreferencesAppSettingsRepository();
      await restarted.repertoireBooks.ensureLoaded();
      expect(restarted.repertoireBooks.state.committed!.white, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
