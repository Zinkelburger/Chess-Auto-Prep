// The players' wiring: the analysis follows its player's record but not
// its removal; a download keeps the range first and runs only once it is
// kept; studies are linked beside those already linked and opened at the
// chapter named; a group study that could not be made is not linked; and
// a prep sheet is copied, or saved where the export put it, or the reason
// it was not is said.
import 'package:chess_auto_prep/chess/players/download_range.dart';
import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/player_files.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/study_fixture.dart';
import '../support/window_fixture.dart';

const _games =
    '[Event "Club"]\n[White "Alex"]\n[Black "Bob"]\n[Date "2026.09.20"]\n'
    '[Result "1-0"]\n\n1. e4 e5 1-0\n';

/// The directory in memory, whose next player save can be made to fail.
final class _FlakyPlayers implements PlayerStore {
  final _inner = MemoryPlayers();
  bool failNextSave = false;
  @override
  Future<PlayerDirectory> read() => _inner.read();
  @override
  Future<void> savePlayer(Player player, {Player? expected}) async {
    if (failNextSave) {
      failNextSave = false;
      throw StateError('disk full');
    }
    await _inner.savePlayer(player, expected: expected);
  }

  @override
  Future<void> saveGroup(PlayerGroup group, {PlayerGroup? expected}) =>
      _inner.saveGroup(group, expected: expected);
  @override
  Future<void> removePlayer(Player player) => _inner.removePlayer(player);
  @override
  Future<void> removeGroup(PlayerGroup group) => _inner.removeGroup(group);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WindowFixture w;
  late _FlakyPlayers store;
  late Player player;
  late String? exported;
  Object? exportFails;

  setUp(() async {
    exported = '/Documents/Club.md';
    exportFails = null;
    store = _FlakyPlayers();
    w = WindowFixture(
      players: store,
      exportText: (name, text) async {
        if (exportFails case final thrown?) throw thrown;
        return exported;
      },
    );
    const ref = DocumentRef('/collections/player.pgn');
    w.store.documents[ref] = Opened(_games, scriptedRevision(_games));
    player = Player.create('Alex').edited({
      'pgn_files': [ref.path],
      'lichess': 'alex',
    });
    await w.parts.players.directory.save(player);
  });
  tearDown(() => w.dispose());

  Player stored() => w.parts.players.directory.players.single;

  test('the analysis keeps its player when the record is removed', () async {
    final players = w.parts.players;
    await players.analysis.select(stored());
    await players.directory.remove(stored());
    await pumpEventQueue();
    expect(players.directory.players, isEmpty);
    expect(players.analysis.player?.name, 'Alex');
  });

  group('a download', () {
    /// Every status the analysis shows from now on.
    List<String?> statuses() {
      final said = <String?>[];
      final analysis = w.parts.players.analysis;
      void heard() => said.add(analysis.status);
      analysis.addListener(heard);
      addTearDown(() => analysis.removeListener(heard));
      return said;
    }

    test('keeps the range on the player, then downloads', () async {
      final players = w.parts.players;
      await players.analysis.select(stored());
      final said = statuses();
      await players.download(const PlayerDownloadRange(months: 3));
      expect(stored().fields['download'], isNotNull);
      expect(said, contains(startsWith('Downloading')));
    });

    test('whose range was not kept does not run', () async {
      final players = w.parts.players;
      await players.analysis.select(stored());
      store.failNextSave = true;
      final said = statuses();
      await players.download(const PlayerDownloadRange(months: 3));
      expect(said, isNot(contains(startsWith('Downloading'))));
    });
  });

  group('a linked study', () {
    test('is linked beside the ones already linked', () async {
      final players = w.parts.players;
      for (final name in ['Endgames', 'Openings']) {
        w.viewerPicker.answer = '/Documents/studies/$name.pgn';
        await players.linkStudy(stored());
      }
      expect(
        [
          for (final link in stored().fields['studies']! as List)
            (link as Map)['path'],
        ],
        ['/Documents/studies/Endgames.pgn', '/Documents/studies/Openings.pgn'],
      );
    });

    test('opens at the chapter named', () async {
      final ref = studyRef('Endgames');
      w.store.documents[ref] = Opened(
        twoChapterStudy,
        scriptedRevision(twoChapterStudy),
      );
      await w.parts.players.openLinkedStudy(ref.path, 'Pawn endings');
      expect(w.session.source?.path, ref.path);
      expect(w.session.game, 1);
    });
  });

  test('a group study that could not be made is not linked', () async {
    final directory = w.parts.players.directory;
    final group = PlayerGroup.create('Club');
    await directory.saveGroup(group);
    w.store.creates.add(const IoFailure('disk full'));
    await w.parts.players.openGroupStudy(directory.groups.single);
    expect(directory.groups.single.fields['study'], isNull);
    expect(w.requests.statusIsProblem, isTrue);
  });

  group("a group's prep sheet", () {
    final group = PlayerGroup.create('Club');

    test('copied, says so as news, not a problem', () async {
      await w.parts.players.exportGroup(group, copy: true);
      expect(w.requests.status, 'Prep sheet copied, including saved lines.');
      expect(w.requests.statusIsProblem, isFalse);
    });

    test('exported, says where it went', () async {
      await w.parts.players.exportGroup(group);
      expect(w.requests.status, 'Saved /Documents/Club.md');
    });

    test('not saved anywhere, says nothing', () async {
      exported = null;
      w.requests.say('Earlier');
      await w.parts.players.exportGroup(group);
      expect(w.requests.status, 'Earlier');
    });

    test('that could not be written, says why', () async {
      exportFails = StateError('disk full');
      await w.parts.players.exportGroup(group);
      expect(w.requests.status, startsWith('Could not export the prep sheet'));
    });
  });
}
