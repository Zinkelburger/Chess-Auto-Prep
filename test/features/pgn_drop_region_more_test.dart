// The builder's drop region: it shows where to drop only while a file is
// over it, says so when nothing dropped was a PGN, and takes no drop while
// the library is busy.
import 'dart:async';

import 'package:chess_auto_prep/features/library/pgn_drop_region.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/ui/status_bar.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/library_fixture.dart';
import '../support/scripted_store.dart';

void main() {
  late LibraryFixture fixture;
  late List<String> said;

  Future<void> show(WidgetTester tester, {bool fresh = true}) async {
    if (fresh) {
      fixture = await openLibrary([]);
      addTearDown(fixture.dispose);
      said = [];
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatusScope(
            say: (sentence, {action, problem = true}) => said.add(sentence),
            child: PgnDropRegion(
              library: fixture.library,
              onOpen: (_) {},
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }

  DropTarget target(WidgetTester tester) =>
      tester.widget<DropTarget>(find.byType(DropTarget));
  const where = 'Drop PGN files to import repertoires';

  DropDoneDetails dropped(List<String> paths) => DropDoneDetails(
    files: [for (final path in paths) DropItemFile(path)],
    localPosition: Offset.zero,
    globalPosition: Offset.zero,
  );

  testWidgets('shows where to drop only while a file is over it', (
    tester,
  ) async {
    await show(tester);
    expect(find.text(where), findsNothing);
    target(tester).onDragEntered!(
      DropEventDetails(localPosition: Offset.zero, globalPosition: Offset.zero),
    );
    await tester.pump();
    expect(find.text(where), findsOneWidget);
    target(tester).onDragExited!(
      DropEventDetails(localPosition: Offset.zero, globalPosition: Offset.zero),
    );
    await tester.pump();
    expect(find.text(where), findsNothing);
    target(tester).onDragEntered!(
      DropEventDetails(localPosition: Offset.zero, globalPosition: Offset.zero),
    );
    await tester.pump();
    target(tester).onDragDone!(dropped(['/Downloads/notes.txt']));
    await tester.pumpAndSettle();
    expect(find.text(where), findsNothing, reason: 'the drop ends it');
  });

  testWidgets('says so when nothing dropped was a PGN, and only then', (
    tester,
  ) async {
    await show(tester);
    target(tester).onDragDone!(dropped(['/Downloads/notes.txt']));
    await tester.pumpAndSettle();
    expect(said, contains('Drop a PGN file to import a repertoire.'));
    said.clear();
    const path = '/Downloads/Italian.pgn';
    const text = '[Event "Italian"]\n[Result "*"]\n\n1. e4 e5 *';
    fixture.store.documents[const DocumentRef(path)] = Opened(
      text,
      scriptedRevision(text),
    );
    target(tester).onDragDone!(dropped([path]));
    await tester.pumpAndSettle();
    expect(said, isNot(contains('Drop a PGN file to import a repertoire.')));
  });

  testWidgets('takes drops at rest, and none while the library is busy', (
    tester,
  ) async {
    await show(tester);
    expect(target(tester).enable, isTrue);
    final gate = Completer<void>();
    fixture.store.createGate = gate;
    final making = fixture.library.createRepertoire('Najdorf');
    await tester.pump();
    expect(fixture.library.busy, isTrue);
    // The window draws the region again whenever it redraws.
    await show(tester, fresh: false);
    expect(target(tester).enable, isFalse);
    gate.complete();
    await tester.runAsync(() => making);
    await tester.pumpAndSettle();
  });
}
