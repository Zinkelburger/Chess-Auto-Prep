import 'package:chess_auto_prep/v2/chess/explorer_choice.dart';
import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/net/lichess_explorer.dart';
import 'package:chess_auto_prep/v2/storage/master_book.dart';
import 'package:chess_auto_prep/v2/workspace/explorer_databases.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_explorer.dart';

void main() {
  late ScriptedExplorerApi lichess;
  late ScriptedBook book;
  late ExplorerDatabases databases;

  setUp(() {
    lichess = ScriptedExplorerApi();
    book = ScriptedBook(present: true);
    databases = ExplorerDatabases(lichess: lichess, book: book);
  });

  test('TWIC is asked on this machine, the others over the network', () async {
    const twic = ExplorerChoice(
      source: ExplorerSource.twic,
      classicalOnly: true,
    );
    final (fromBook, _) = await databases.ask(Fen.initial, twic);
    expect(fromBook, same(startAnswer));
    expect(book.asked.single, (Fen.initial, true));
    expect(lichess.asked, isEmpty);
    await databases.ask(Fen.initial, ExplorerChoice.defaults);
    expect(lichess.asked, hasLength(1));
  });

  test('a missing book and an unreachable network each say so', () async {
    book = ScriptedBook(answer: (_, _) => const BookAbsent());
    lichess.answer = (_) =>
        const ExplorerNotFetched(ExplorerProblem.unreachable);
    databases = ExplorerDatabases(lichess: lichess, book: book);
    final (_, noBook) = await databases.ask(
      Fen.initial,
      const ExplorerChoice(source: ExplorerSource.twic),
    );
    expect(noBook, 'There is no master database on this machine.');
    final (_, offline) = await databases.ask(
      Fen.initial,
      ExplorerChoice.defaults,
    );
    expect(offline, ExplorerProblem.unreachable.sentence);
    databases = ExplorerDatabases(
      lichess: lichess,
      book: ScriptedBook(present: true),
    );
    final (_, offlineWithBook) = await databases.ask(
      Fen.initial,
      ExplorerChoice.defaults,
    );
    expect(offlineWithBook, endsWith('TWIC works offline.'));
  });
}
