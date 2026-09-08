import 'dart:async';

import 'package:chess_auto_prep/features/opponents/models/person_record.dart';
import 'package:chess_auto_prep/features/opponents/services/opponent_store.dart';
import 'package:chess_auto_prep/features/opponents/services/player_list_parser.dart';
import 'package:chess_auto_prep/features/opponents/services/prep_files.dart';
import 'package:chess_auto_prep/features/opponents/services/tournament_import.dart';
import 'package:chess_auto_prep/features/opponents/widgets/player_cell.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _SlowStorage extends MemoryOpponentStorage {
  final first = Completer<void>();
  int writes = 0;
  @override
  Future<void> writePeople(String json) async {
    writes++;
    if (writes == 1) await first.future;
    await super.writePeople(json);
  }
}

class _Studies extends Fake implements StorageService {
  final files = <String, String>{};
  @override
  Future<String> studyFilePath(String name) async => '/studies/$name.pgn';
  @override
  Future<bool> fileExists(String path) async => files.containsKey(path);
  @override
  Future<String?> readFile(String path) async => files[path];
  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    if (createOnly && files.containsKey(path)) throw StateError('exists');
    files[path] = content;
  }
}

void main() {
  test(
    'rapid edits and linked studies survive reopening, in write order',
    () async {
      final disk = _SlowStorage();
      final store = OpponentStore(disk);
      await store.ensureLoaded();
      final person = PersonRecord.create(
        name: 'Jane',
        chesscom: 'jane, Jane_alt; JANE',
      );
      final first = store.savePerson(person);
      await Future<void>.delayed(Duration.zero);
      final second = store.savePerson(
        person.copyWith(
          name: 'Jane Doe',
          uscfId: '12345678',
          notes: 'Try the early c4 line.',
          gameSetKeys: ['player-saved'],
          studyLinks: [
            const PlayerStudyLink(
              path: '/studies/Boylston.pgn',
              chapter: 'Jane · As White',
            ),
          ],
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        disk.writes,
        1,
        reason: 'newer snapshots must not overtake old writes',
      );
      disk.first.complete();
      await Future.wait([first, second]);
      final reopened = OpponentStore(disk);
      await reopened.ensureLoaded();
      final saved = reopened.people.single;
      expect(saved.name, 'Jane Doe');
      expect(saved.accounts.map((a) => a.username), ['jane', 'Jane_alt']);
      expect(saved.uscfId, '12345678');
      expect(saved.notes, 'Try the early c4 line.');
      expect(saved.studyLinks.single.chapter, 'Jane · As White');
      expect(saved.gameSetKeys, ['player-saved']);
      expect(reopened.matchPerson(chesscom: 'jane_ALT')?.id, saved.id);
    },
  );

  test(
    'Boylston pasted table keeps unmatched people and reuses USCF identities',
    () async {
      const table =
          '#\tName\tRating\tUSCF ID\tSection\tByes\n'
          '1\tKateryna Odnorozhenko (WIM)\t2044\t30200342\t\t\n'
          '2\tBrian Boughton\t1105\t33122930\t\t\n'
          '3\tJustin Lei\t1075\t16460150\t\t\n'
          '4\tSoroush Samadani\tunr\t33224775\t\t';
      final store = OpponentStore(MemoryOpponentStorage());
      await store.ensureLoaded();
      final known = await store.savePerson(
        PersonRecord.create(
          name: 'Brian',
          uscfId: '33122930',
          chesscom: 'example_handle',
        ),
      );
      final group = await store.createTournament('Boylston');
      final imported = await TournamentImport(
        store,
      ).importList(parsePlayerList(table), tournament: group);
      expect(imported.tournament.entries.length, 4);
      expect(imported.newPeople, 3);
      expect(store.person(known.id)!.chesscom, 'example_handle');
      expect(store.matchPerson(uscfId: '33224775')!.rating, isNull);
      expect(store.matchPerson(uscfId: '33224775')!.hasAccount, isFalse);
      final again = await TournamentImport(
        store,
      ).importList(parsePlayerList(table), tournament: imported.tournament);
      expect(again.added, 0);
    },
  );

  test('HTML entry links and markdown/CSV tables parse visible player data', () {
    const html =
        '<table><tr><th>#</th><th>Name</th><th>Rating</th><th>USCF ID</th></tr>'
        '<tr><td>1</td><td>Jane &amp; Doe</td><td>1800</td><td><a href="/player/12345678">12345678</a></td></tr></table>';
    expect(
      parsePlayerList(playerTableTextFromHtml(html)).opponents.single.uscfId,
      '12345678',
    );
    expect(
      parsePlayerList(
        'Name,USCF ID,Rating\n"Doe, Jane",12345678,1800',
      ).opponents.single.name,
      'Doe, Jane',
    );
    expect(
      parsePlayerList(
        '| Name | USCF ID |\n| --- | --- |\n| Jane | [12345678](https://example.com) |',
      ).opponents.single.uscfId,
      '12345678',
    );
  });

  test(
    'group study is persistent and never regenerates over edited notes',
    () async {
      final disk = MemoryOpponentStorage();
      final store = OpponentStore(disk);
      await store.ensureLoaded();
      final studies = _Studies();
      StorageFactory.instanceForTest = studies;
      addTearDown(() => StorageFactory.instanceForTest = null);
      final group = await store.createTournament('Boylston');
      final path = await PrepFiles(store).ensureGroup(group);
      studies.files[path] = '[Event "Brian - my ideas"]\n\n1. e4 c5 *';
      final reopened = OpponentStore(disk);
      await reopened.ensureLoaded();
      expect(
        await PrepFiles(reopened).ensureGroup(reopened.tournaments.single),
        path,
      );
      expect(studies.files[path], contains('my ideas'));
    },
  );

  testWidgets(
    'failed autosave stays visible and Enter retries without a popup',
    (tester) async {
      var fail = true;
      String? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerCell(
              value: 'Jane',
              label: 'Name',
              save: (value) async {
                if (fail) throw StateError('disk full');
                saved = value;
              },
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'Jane Doe');
      await tester.pumpAndSettle();
      expect(find.text('Not saved. Press Enter to retry.'), findsOneWidget);
      fail = false;
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(saved, 'Jane Doe');
      expect(find.text('Not saved. Press Enter to retry.'), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
}
