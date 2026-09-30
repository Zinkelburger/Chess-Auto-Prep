import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/features/players/players.dart';
import 'package:chess_auto_prep/net/player_ratings.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/storage/player_files.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late PlayerFiles files;
  late PendingWrites pending;
  late Map<String, Completer<PlayerRating>> lookups;
  late Players owner;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('players-owner-test-');
    files = PlayerFiles(dir);
    await files.savePlayer(Player.create('A').edited({'uscf_id': '11111111'}));
    await files.savePlayer(Player.create('B').edited({'uscf_id': '22222222'}));
    pending = PendingWrites();
    lookups = {
      '11111111': Completer<PlayerRating>(),
      '22222222': Completer<PlayerRating>(),
    };
    owner = Players(files, pending, lookupRating: (id) => lookups[id]!.future);
    await owner.load();
  });
  tearDown(() async {
    owner.dispose();
    await dir.delete(recursive: true);
  });

  Player named(String name) => owner.players.firstWhere((p) => p.name == name);

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(done(), isTrue);
  }

  test('an edit made while ratings are looked up is kept and the next '
      'rating is saved over it', () async {
    final running = owner.updateRatings();
    lookups['11111111']!.complete((name: 'A', rating: 1500));
    await until(
      () => named('A').text('rating') == '1500' && owner.busy == false,
    );
    expect(owner.lookupStatus, contains('2 / 2'));
    final b = named('B');
    expect(await owner.save(b.edited({'notes': 'x'}), expected: b), isTrue);
    lookups['22222222']!.complete((name: 'B', rating: 1700));
    await running;
    expect(owner.needsRetry, isFalse);
    expect(named('B').text('notes'), 'x');
    expect(named('B').text('rating'), '1700');
    expect(named('A').text('rating'), '1500');
    final a = named('A');
    expect(await owner.save(a.edited({'notes': 'y'}), expected: a), isTrue);
    expect(await pending.settle(), isNull);
  });

  test('a save over a row another window changed is refused, reloads the '
      'rows and leaves later saves free', () async {
    final a = named('A');
    await PlayerFiles(
      dir,
    ).savePlayer(a.edited({'notes': 'other window'}), expected: a);
    expect(await owner.save(a.edited({'rating': 1}), expected: a), isFalse);
    expect(owner.needsRetry, isFalse);
    expect(owner.error, contains('another window'));
    final latest = named('A');
    expect(latest.text('notes'), 'other window');
    expect(
      await owner.save(latest.edited({'rating': 2}), expected: latest),
      isTrue,
    );
    expect(named('A').text('notes'), 'other window');
    expect(await pending.settle(), isNull);
  });

  test('retrying a failed save over a row another window changed drops it '
      'and leaves later saves free', () async {
    final flaky = _FailOnce(files);
    final retrying = Players(flaky, pending);
    addTearDown(retrying.dispose);
    await retrying.load();
    final a = retrying.players.firstWhere((p) => p.name == 'A');
    flaky.failNext = true;
    expect(await retrying.save(a.edited({'rating': 1}), expected: a), isFalse);
    expect(retrying.needsRetry, isTrue);
    await files.savePlayer(a.edited({'notes': 'other window'}), expected: a);
    await retrying.retry();
    expect(retrying.needsRetry, isFalse);
    expect(retrying.error, contains('another window'));
    final latest = retrying.players.firstWhere((p) => p.name == 'A');
    expect(latest.text('notes'), 'other window');
    expect(
      await retrying.save(latest.edited({'rating': 2}), expected: latest),
      isTrue,
    );
    expect(await pending.settle(), isNull);
  });
}

/// [PlayerFiles] whose next player save fails like a disk error.
final class _FailOnce implements PlayerStore {
  _FailOnce(this.files);
  final PlayerFiles files;
  bool failNext = false;

  @override
  Future<PlayerDirectory> read() => files.read();
  @override
  Future<void> savePlayer(Player player, {Player? expected}) async {
    if (failNext) {
      failNext = false;
      throw const FileSystemException('disk full');
    }
    return files.savePlayer(player, expected: expected);
  }

  @override
  Future<void> saveGroup(PlayerGroup group, {PlayerGroup? expected}) =>
      files.saveGroup(group, expected: expected);
  @override
  Future<void> removePlayer(Player player) => files.removePlayer(player);
  @override
  Future<void> removeGroup(PlayerGroup group) => files.removeGroup(group);
}
