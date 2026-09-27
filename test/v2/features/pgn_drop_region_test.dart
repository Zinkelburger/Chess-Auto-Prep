import 'package:chess_auto_prep/v2/features/library/pgn_drop_region.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/ui/error_bar.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/library_fixture.dart';
import '../support/scripted_store.dart';

void main() {
  testWidgets('native drop imports a PGN once and opens the result', (
    tester,
  ) async {
    final fixture = await openLibrary([]);
    addTearDown(fixture.dispose);
    const path = '/Downloads/Italian.pgn';
    const text = '[Event "Italian"]\n[Result "*"]\n\n1. e4 e5 *';
    fixture.store.documents[const DocumentRef(path)] = Opened(
      text,
      scriptedRevision(text),
    );
    final opened = <ChapterRef>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatusScope(
            say: (_, {action}) {},
            child: PgnDropRegion(
              library: fixture.library,
              onOpen: opened.add,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    final region = tester.widget<DropTarget>(find.byType(DropTarget));
    region.onDragDone!(
      DropDoneDetails(
        files: [
          DropItemFile(path),
          DropItemFile(path),
          DropItemFile('/Downloads/ignore.txt'),
        ],
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      ),
    );
    await tester.pumpAndSettle();
    expect(opened, hasLength(1));
    expect(fixture.textAt(opened.single.path), contains('1. e4 e5'));
    expect(fixture.textAt(path), text);
  });
}
