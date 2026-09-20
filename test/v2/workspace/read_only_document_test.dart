import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart' show Opened;
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/edit_refused.dart';
import 'package:chess_auto_prep/v2/workspace/save_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/session_fixture.dart';

const _notUtf8 =
    'this file is not UTF-8; open and save it in the old app to convert it, '
    'then edit it here';

void main() {
  late SessionFixture fixture;

  setUp(() async {
    fixture = await openSession(blackChapter, readOnly: _notUtf8);
  });

  tearDown(() => fixture.dispose());

  test('says so the moment it opens', () {
    expect(fixture.session.readOnly, _notUtf8);
    expect(fixture.session.refusedEdit, isA<NotEditable>());
    expect(fixture.saver.state, isA<DocumentReadOnly>());
  });

  test('takes no move and asks the store for nothing', () async {
    fixture.session.playMove('g1f3');
    await pumpEventQueue();
    expect(fixture.session.refusedEdit, isA<NotEditable>());
    expect(fixture.store.requestedSaves, isEmpty);
    expect(fixture.onDisk, blackChapter);
  });

  test('takes no comment either', () async {
    fixture.session.setComment(NodePath.of([0]), 'mine');
    await pumpEventQueue();
    expect(fixture.session.refusedEdit, isA<NotEditable>());
    expect(fixture.store.requestedSaves, isEmpty);
  });

  test('has nothing unsaved, so the closing window never asks', () {
    expect(fixture.saver.settled, isTrue);
  });

  test('can still be written somewhere else', () async {
    expect(await fixture.session.saveCopy('Converted'), isA<CopySaved>());
    final copy = fixture.store.documents.entries.firstWhere(
      (entry) => entry.key.path.endsWith('Converted.pgn'),
    );
    expect((copy.value as Opened).text, writeChapter(fixture.session.chapter!));
  });
}
