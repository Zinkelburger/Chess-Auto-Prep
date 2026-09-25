import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/my_accounts.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/local_games.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/window_fixture.dart';

const _first = '[Event "First"]\n\n1. e4 e5 *';
const _second = '[Event "Second"]\n\n1. d4 d5 *';

void main() {
  test('committed corpus edits revoke answers before a new read', () async {
    final window = WindowFixture();
    addTearDown(window.dispose);
    window.accounts.accounts[GameSite.lichess] = const Account('Me');
    final ref = window.gamesCache.refFor(GameSite.lichess, 'Me');
    window.store.documents[ref] = Opened(_first, scriptedRevision(_first));
    final tree = window.parts.workspace.myGamesTree;
    tree.want();
    await pumpEventQueue();
    expect(tree.state, isA<TreeBuilt>());
    expect(tree.answerAt(Fen.initial)!.moves.single.uci, 'e2e4');

    // An unrelated document leaves the already-validated tree intact.
    await window.parts.env.store.create(
      const DocumentRef('/pgn_collections/Other.pgn'),
      _second,
    );
    expect(tree.state, isA<TreeBuilt>());

    await window.parts.env.store.save(
      ref,
      _second,
      expected: scriptedRevision(_first),
      scope: const WholeDocument(),
    );
    expect(tree.answerAt(Fen.initial), isNull);
    tree.want();
    await pumpEventQueue();
    expect(tree.answerAt(Fen.initial)!.moves.single.uci, 'd2d4');

    await window.parts.env.store.delete(
      ref,
      expected: scriptedRevision(_second),
    );
    expect(tree.answerAt(Fen.initial), isNull);
    tree.want();
    await pumpEventQueue();
    expect(tree.state, isA<TreeEmpty>());
    await window.parts.env.store.create(ref, _first);
    expect(tree.state, isA<TreeUnbuilt>());
    tree.want();
    await pumpEventQueue();
    expect(tree.answerAt(Fen.initial)!.moves.single.uci, 'e2e4');
  });
}
