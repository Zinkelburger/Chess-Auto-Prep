// The builder's drop region: it shows where to drop only while a file is
// over it, says so when nothing dropped was a PGN, and takes no drop while
// the library is busy.
import 'dart:async';

import 'package:chess_auto_prep/features/library/pgn_drop_region.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/ui/status_bar.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/library_fixture.dart';
import '../support/scripted_store.dart';

void main() {
  late LibraryFixture fixture;
  late PendingWrites pending;
  late List<String> said;
  late List<String> opened;

  Future<void> show(WidgetTester tester, {bool fresh = true}) async {
    if (fresh) {
      pending = PendingWrites();
      fixture = await openLibrary([], pendingWrites: pending);
      addTearDown(fixture.dispose);
      said = [];
      opened = [];
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatusScope(
            say: (sentence, {action, problem = true}) => said.add(sentence),
            child: PgnDropRegion(
              library: fixture.library,
              onOpen: (ref) => opened.add(ref.path),
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

  testWidgets('all dropped PGNs finish importing after leaving the builder', (
    tester,
  ) async {
    await show(tester);
    const first = '/Downloads/A.pgn';
    const second = '/Downloads/B.pgn';
    for (final (path, moves) in [(first, '1. e4 e5'), (second, '1. d4 d5')]) {
      final text = '[Event "Club"]\n[Result "*"]\n\n$moves *';
      fixture.store.documents[DocumentRef(path)] = Opened(
        text,
        scriptedRevision(text),
      );
    }
    final gate = fixture.store.readEarly = Completer<void>();
    target(tester).onDragDone!(dropped([first, second]));
    await tester.pump();
    expect(fixture.store.opened.last.path, first);
    var settled = false;
    final closing = pending.settle().then((problem) {
      settled = true;
      return problem;
    });
    await tester.pumpWidget(const SizedBox.shrink());
    final secondRead = fixture.store.readEarly = Completer<void>();
    gate.complete();
    await tester.pump();
    expect(fixture.store.opened.last.path, second);
    await show(tester, fresh: false);
    expect(target(tester).enable, isFalse);
    expect(settled, isFalse);
    secondRead.complete();
    await tester.pumpAndSettle();

    expect(await closing, isNull);
    expect(fixture.textAt('/repertoires/A/Main.pgn'), contains('1. e4 e5'));
    expect(fixture.textAt('/repertoires/B/Main.pgn'), contains('1. d4 d5'));
    expect(opened, isEmpty);
    expect(target(tester).enable, isTrue);
    target(tester).onDragDone!(dropped(['/Downloads/Missing.pgn']));
    await tester.pumpAndSettle();
    expect(said, contains('Could not read that file.'));
  });

  testWidgets('a drop waits for a change started during catalog refresh', (
    tester,
  ) async {
    await show(tester);
    const first = '/Downloads/First.pgn';
    const second = '/Downloads/Second.pgn';
    const text = '[Event "Club"]\n[Result "*"]\n\n1. e4 e5 *';
    for (final path in [first, second]) {
      fixture.store.documents[DocumentRef(path)] = Opened(
        text,
        scriptedRevision(text),
      );
    }
    fixture.files.hold = true;
    target(tester).onDragDone!(dropped([first, second]));
    await tester.pump();
    expect(fixture.files.pendingCalls, 1);
    final gate = fixture.store.createGate = Completer<void>();
    final making = fixture.library.createRepertoire('Other');
    fixture.files
      ..hold = false
      ..releaseNext();
    await tester.pump();
    expect(opened, ['/repertoires/First/Main.pgn']);
    expect(fixture.store.opened.last.path, first);

    gate.complete();
    await making;
    await tester.pumpAndSettle();
    expect(fixture.textAt('/repertoires/Other/Main.pgn'), isNotNull);
    expect(
      fixture.textAt('/repertoires/Second/Main.pgn'),
      contains('1. e4 e5'),
    );
    expect(opened, [
      '/repertoires/First/Main.pgn',
      '/repertoires/Second/Main.pgn',
    ]);
    expect(said, isEmpty);
  });

  testWidgets('takes drops at rest, and none while the library is busy', (
    tester,
  ) async {
    await show(tester);
    expect(target(tester).enable, isTrue);
    final gate = Completer<void>();
    fixture.store.createGate = gate;
    final making = fixture.library.createRepertoire('Najdorf');
    target(tester).onDragDone!(dropped(['/Downloads/TooLate.pgn']));
    await tester.pump();
    expect(fixture.library.busy, isTrue);
    expect(target(tester).enable, isFalse);
    gate.complete();
    await making;
    await tester.pumpAndSettle();
    expect(target(tester).enable, isTrue);
    expect(fixture.store.opened, isEmpty);
    expect(said, contains('Another change is still running.'));
  });
}
