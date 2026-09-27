import 'package:chess_auto_prep/v2/chess/players/player.dart';
import 'package:chess_auto_prep/v2/features/players/prep_sheet.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_store.dart';

void main() {
  test(
    'export includes only group members, metadata, notes and prep moves',
    () async {
      final person = Player.create(
        'Alex | Rivera',
      ).edited({'prep_file': '/prep.pgn', 'notes': 'Review the Sicilian.'});
      final group = PlayerGroup.create('Club Open')
          .edited({'date': '2026-09-27', 'rounds': 5})
          .member(person.id, prepared: true);
      final store = ScriptedDocumentStore();
      const text =
          '[Event "Prep"]\n[ChapterName "As Black"]\n\n1. e4 c5 {Check the move order.} *';
      store.documents[const DocumentRef('/prep.pgn')] = Opened(
        text,
        scriptedRevision(text),
      );
      final sheet = await prepSheet(group, [
        person,
        Player.create('Not in this event'),
      ], store);
      expect(sheet, contains('5 rounds · 1 players · 1 prepared'));
      expect(sheet, contains(r'Alex \| Rivera'));
      expect(sheet, contains('Review the Sicilian.'));
      expect(sheet, contains('1. e4 c5 {Check the move order.}'));
      expect(sheet, isNot(contains('Not in this event')));
    },
  );
  test('unreadable prep is an explicit export failure', () async {
    final person = Player.create('Alex').edited({'prep_file': '/missing.pgn'});
    final group = PlayerGroup.create('Open').member(person.id);
    await expectLater(
      prepSheet(group, [person], ScriptedDocumentStore()),
      throwsStateError,
    );
  });
}
