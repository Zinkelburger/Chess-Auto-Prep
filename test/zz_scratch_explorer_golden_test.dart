// Throwaway render of the explorer panel on the TWIC source. Not committed.
@TestOn('vm')
library;

import 'dart:io';

import 'package:chess_auto_prep/services/lichess_api_client.dart';
import 'package:chess_auto_prep/services/live_explorer_service.dart';
import 'package:chess_auto_prep/services/master_games/master_games_importer.dart';
import 'package:chess_auto_prep/services/master_games/master_games_service.dart';
import 'package:chess_auto_prep/theme/app_colors.dart';
import 'package:chess_auto_prep/theme/app_text_styles.dart';
import 'package:chess_auto_prep/widgets/opening_explorer/opening_explorer_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'features/master_games/master_practice_fixtures.dart';

Future<void> _loadFont(String family, List<String> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    final bytes = File('assets/fonts/$f').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

const _fen = 'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';

void main() {
  testWidgets('render', (tester) async {
    await _loadFont('Inter', ['Inter-Regular.ttf', 'Inter-Medium.ttf', 'Inter-SemiBold.ttf', 'Inter-Bold.ttf']);
    await _loadFont('SourceCodePro', ['SourceCodePro-Regular.ttf', 'SourceCodePro-Semibold.ttf', 'SourceCodePro-Bold.ttf']);
    SharedPreferences.setMockInitialValues({'live_explorer.db': 'twic'});
    final tmp = Directory.systemTemp.createTempSync('explorer_golden');
    final dbPath = '${tmp.path}/master_games.db';
    importPgnIntoMasterGames(MasterGamesImportRequest(dbPath: dbPath, pgnText: masterPgn, twicIssue: 1660));
    final service = MasterGamesService(dbPathProvider: () async => dbPath);
    await tester.runAsync(service.load);
    final explorer = LiveExplorerService(client: LichessApiClient.fresh(), isLoggedIn: () => false, localDb: () => service.db);
    tester.view.physicalSize = const Size(420, 620);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(
        colorScheme: const ColorScheme.dark(
          surface: AppColors.surface, onSurface: AppColors.ink, primary: AppColors.ink,
          onPrimary: AppColors.surface, primaryContainer: AppColors.surfaceContainer,
          onPrimaryContainer: AppColors.ink, secondary: AppColors.surfaceHighlight,
          onSecondary: AppColors.ink, error: AppColors.danger, onError: AppColors.ink,
        ),
        scaffoldBackgroundColor: AppColors.surface,
        fontFamily: AppTextStyles.uiFamily,
        dividerColor: AppColors.divider,
        textTheme: AppTextStyles.materialTextTheme(),
      ),
      home: Scaffold(body: OpeningExplorerPanel(
        service: explorer, fen: _fen, onPlayMove: (_) {}, onOpenGame: (_) async {}, masterGames: service,
      )),
    ));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('/tmp/claude-4215325/-home-anbernal-Projects-Chess-Auto-Prep/96c7f529-d76a-4218-9972-101acd360bf1/scratchpad/shots/explorer-twic.png'));
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await expectLater(find.byType(MaterialApp), matchesGoldenFile('/tmp/claude-4215325/-home-anbernal-Projects-Chess-Auto-Prep/96c7f529-d76a-4218-9972-101acd360bf1/scratchpad/shots/explorer-twic-filters.png'));
    explorer.dispose();
    service.dispose();
  });
}
