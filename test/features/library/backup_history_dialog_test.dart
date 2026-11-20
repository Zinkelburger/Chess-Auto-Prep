// Version history: pick a kept version, read it, and hand it back to be
// restored as a new repertoire.

import 'package:chess_auto_prep/features/library/backup_history_dialog.dart';
import 'package:chess_auto_prep/storage/backup_history.dart';
import 'package:chess_auto_prep/storage/backups.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../storage/store_fixture.dart';

void main() {
  late StoreFixture disk;

  /// Shows the dialog over [ref]'s history; [answer] gets what it returns.
  Future<void> show(
    WidgetTester tester,
    ChapterRef ref,
    void Function(String?) answer,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final history = BackupHistory(disk.store.recovery);
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                answer(await showBackupHistory(context, history, ref)),
            child: const Text('History'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('History'));
    await settle(tester);
  }

  testWidgets('a picked version is previewed and handed back to restore', (
    tester,
  ) async {
    late ChapterRef ref;
    late BackupVersion kept;
    final old = oneGame('1. e4');
    await tester.runAsync(() async {
      disk = await StoreFixture.create();
      final document = disk.ref('repertoires/Main/Main.pgn');
      ref = ChapterRef.at(document.path);
      final revision = await disk.put(document, old);
      await disk.edit(document, oneGame('1. d4'), revision);
      kept = (await BackupHistory(disk.store.recovery).versions(ref)).single;
    });
    addTearDown(() => tester.runAsync(disk.dispose));
    String? restored;
    var answered = false;
    await show(tester, ref, (text) {
      answered = true;
      restored = text;
    });

    final restore = find.widgetWithText(
      FilledButton,
      'Restore as new repertoire',
    );
    expect(tester.widget<FilledButton>(restore).onPressed, isNull);
    expect(find.text('Select a version to preview its PGN.'), findsOneWidget);

    // Each version is named by when it was kept, to the second.
    final local = kept.time.toLocal();
    String two(int n) => '$n'.padLeft(2, '0');
    final when =
        '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
    await tester.tap(find.text(when));
    await settle(tester);
    expect(find.text(old), findsOneWidget);
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, when)).selected,
      isTrue,
      reason: 'the version previewed is the one marked',
    );

    await tester.tap(restore);
    await settle(tester);
    expect(answered, isTrue);
    expect(restored, old);
  });

  testWidgets('a file with no kept version says so', (tester) async {
    late ChapterRef ref;
    await tester.runAsync(() async {
      disk = await StoreFixture.create();
      final document = disk.ref('repertoires/Main/Main.pgn');
      ref = ChapterRef.at(document.path);
      await disk.put(document, oneGame('1. e4'));
    });
    addTearDown(() => tester.runAsync(disk.dispose));
    await show(tester, ref, (_) {});

    expect(find.text('No earlier versions.'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(
            find.widgetWithText(
              TextButton,
              'Delete older versions beyond those limits',
            ),
          )
          .onPressed,
      isNull,
      reason: 'nothing is past the limits to delete',
    );
  });
}

/// Lets the dialog's disk reads finish and the frames they cause land. The
/// dialog's progress bar never settles while a read is out, so this pumps
/// for a while rather than until nothing is scheduled.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}
