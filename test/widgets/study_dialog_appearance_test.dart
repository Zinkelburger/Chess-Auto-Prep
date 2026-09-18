import 'package:chess_auto_prep/chess_core/moves/move_tree_snapshot.dart';
import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/features/studies/models/study_projection.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:chess_auto_prep/widgets/pgn/add_to_study_dialog.dart';
import 'package:chess_auto_prep/widgets/study/edit_chapter_dialog.dart';
import 'package:chess_auto_prep/widgets/study/new_chapter_dialog.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final light in [false, true]) {
    for (final kind in ['new', 'edit', 'add']) {
      testWidgets(
        '$kind chapter dialog at 200% in ${light ? 'light' : 'dark'}',
        (tester) async {
          tester.view.physicalSize = const Size(640, 700);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          Object? result;
          final theme = light ? AppTheme.light() : AppTheme.dark();
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
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
                    child: const Text('Open'),
                    onPressed: () async {
                      result = switch (kind) {
                        'new' => await showNewChapterDialog(
                          context,
                          defaultName: 'A long chapter name with several words',
                        ),
                        'edit' => await showEditChapterDialog(
                          context,
                          chapter: StudyChapterProjection(
                            session: Object(),
                            key: Object(),
                            revision: 0,
                            name: 'A long chapter name with several words',
                            orientation: Side.white,
                            headers: {'Annotator': 'A long annotator name'},
                            tree: MoveTreeSnapshot.capture(MoveTree()),
                          ),
                        ),
                        _ => await showDialog<AddToStudyResult>(
                          context: context,
                          builder: (_) => AddToStudyDialog(
                            initialChapterName: 'My chapter',
                            loadStudies: () async => [
                              RepertoireMetadata(
                                filePath: '/long.pgn',
                                name: 'A long study name with several words',
                                lastModified: DateTime(2026),
                              ),
                            ],
                          ),
                        ),
                      };
                    },
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final dialogContext = tester.element(find.byType(AlertDialog));
          expect(Theme.of(dialogContext).brightness, theme.brightness);
          if (kind == 'new') {
            await tester.tap(find.text('PGN'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            final field = find.widgetWithText(
              TextField,
              AppLocalizations.of(dialogContext).studyPasteChaptersHint,
            );
            await tester.ensureVisible(field);
            await tester.enterText(field, '1. e4 *');
            await tester.tap(
              find.text(AppLocalizations.of(dialogContext).studyCreate),
            );
            await tester.pumpAndSettle();
            expect(result, isA<NewChaptersFromPgn>());
          } else if (kind == 'edit') {
            await tester.tap(
              find.text(AppLocalizations.of(dialogContext).saveChanges),
            );
            await tester.pumpAndSettle();
            expect(result, isA<ChapterEdit>());
          } else {
            final search = find.widgetWithText(
              TextField,
              'Search existing studies',
            );
            await tester.enterText(search, 'long study');
            await tester.testTextInput.receiveAction(TextInputAction.done);
            await tester.pumpAndSettle();
            expect((result as AddToStudyResult).existingPath, '/long.pgn');
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
