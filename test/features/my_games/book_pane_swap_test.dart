// The Book tab handed another book: the new one is read, and the old one is
// no longer watched.
import 'package:chess_auto_prep/features/my_games/book_pane.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/document/document_saver.dart';
import 'package:chess_auto_prep/workspace/document/document_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/book_fixture.dart';

void main() {
  testWidgets('another book is watched in place of the first', (tester) async {
    final first = BookFixture();
    final second = BookFixture();
    final saver = DocumentSaver(first.store, delay: Duration.zero);
    final session = DocumentSession(first.store, saver);
    addTearDown(() {
      first.dispose();
      second.dispose();
      session.dispose();
      saver.dispose();
    });
    Future<void> pane(BookFixture fixture) => tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: BookPane(
            book: fixture.book,
            session: session,
            onReadBook: (_) {},
          ),
        ),
      ),
    );

    await pane(first);
    await tester.pumpAndSettle();
    expect(first.accounts.snapshots, greaterThan(0));
    expect(second.accounts.snapshots, 0);
    await pane(second);
    await tester.pumpAndSettle();
    expect(second.accounts.snapshots, greaterThan(0), reason: 'read now');
    final firstReads = first.accounts.snapshots;
    first.book.recheck();
    await tester.pumpAndSettle();
    expect(first.accounts.snapshots, firstReads, reason: 'no longer watched');
  });
}
