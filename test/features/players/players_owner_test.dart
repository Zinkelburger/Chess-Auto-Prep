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

  test('correcting a US Chess ID discards the old identity’s rating', () async {
    final rating = owner.updateRatings();
    expect(owner.lookupStatus, contains('Looking up A'));
    final a = named('A');
    expect(
      await owner.save(
        a.edited({'uscf_id': '33333333', 'rating': 1400}),
        expected: a,
      ),
      isTrue,
    );
    lookups['11111111']!.complete((name: 'A', rating: 1950));
    lookups['22222222']!.complete((name: 'B', rating: null));
    await rating;
    expect(named('A').text('uscf_id'), '33333333');
    expect(named('A').text('rating'), '1400');
  });

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
    expect(owner.lookupStatus, '2 ratings updated · 0 unavailable');
    final a = named('A');
    expect(await owner.save(a.edited({'notes': 'y'}), expected: a), isTrue);
    expect(await pending.settle(), isNull);
  });

  test('a rating that comes back after Stop is not saved, and nobody after '
      'it is looked up', () async {
    final running = owner.updateRatings();
    expect(owner.lookupStatus, contains('Looking up A'));
    owner.stopLookup();
    lookups['11111111']!.complete((name: 'A', rating: 1500));
    await running;
    expect(named('A').text('rating'), isEmpty);
    expect(owner.lookupStatus, '0 ratings updated · 0 unavailable');
    expect(owner.lookingUp, isFalse);
  });

  test('a directory not read yet says so, and is read once loaded', () async {
    final fresh = Players(files, pending);
    addTearDown(fresh.dispose);
    expect(fresh.loaded, isFalse);
    await fresh.load();
    expect(fresh.loaded, isTrue);
    expect(fresh.players, hasLength(2));
  });

  test('taking the directory down while it is read is safe', () async {
    final gate = Completer<void>();
    final slow = Players(_Gated(files, gate.future), pending);
    final loading = slow.load();
    slow.dispose();
    gate.complete();
    await expectLater(loading, completes);
    expect(slow.players, isEmpty);
  });

  test('players pasted into a group join that group', () async {
    final club = PlayerGroup.create('Club');
    final other = PlayerGroup.create('Other');
    await files.saveGroup(other);
    await files.saveGroup(club);
    await owner.load();
    owner.showGroup(club.id);
    expect(await owner.import([Player.create('Dana')]), isTrue);
    final dana = named('Dana');
    final groups = {for (final g in owner.groups) g.name: g};
    expect(groups['Club']!.contains(dana.id), isTrue);
    expect(groups['Other']!.contains(dana.id), isFalse);
    expect(owner.visible.map((p) => p.name), ['Dana']);
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

  test(
    'a failed save says what the user can act on, never the exception',
    () async {
      final flaky = _FailOnce(files);
      final failing = Players(flaky, pending);
      addTearDown(failing.dispose);
      await failing.load();
      final a = failing.players.firstWhere((p) => p.name == 'A');
      flaky.failNext = true;
      expect(await failing.save(a.edited({'rating': 1}), expected: a), isFalse);
      expect(failing.error, 'Could not save. The disk is full.');
      flaky.failWith = StateError('Internal: list was modified');
      flaky.failNext = true;
      await failing.retry();
      expect(failing.error, 'Could not save.');
    },
  );

  test('reloads that keep failing behind a failed save say so once', () async {
    final flaky = _FailOnce(files);
    final failing = Players(flaky, pending);
    addTearDown(failing.dispose);
    await failing.load();
    final a = failing.players.firstWhere((p) => p.name == 'A');
    flaky.failNext = true;
    expect(await failing.save(a.edited({'rating': 1}), expected: a), isFalse);
    flaky.failReads = true;
    await failing.load();
    await failing.load();
    await failing.load();
    expect(failing.needsRetry, isTrue);
    expect(failing.error, startsWith('Could not save. The disk is full.'));
    expect(
      'Could not load players'.allMatches(failing.error!).length,
      1,
      reason: failing.error,
    );
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

  test('an imported row goes to the person with its US Chess ID before one '
      'who only shares its name', () async {
    await files.savePlayer(
      Player.create('Alex Kim').edited({'lichess': 'alexk'}),
    );
    await files.savePlayer(
      Player.create('Alexander Kim').edited({
        'uscf_id': '12345678',
        'aliases': ['Alex Kim'],
      }),
    );
    await owner.load();
    final imported = Player.create(
      'Alex Kim',
    ).edited({'uscf_id': '12345678', 'notes': 'from the roster'});
    expect(await owner.import([imported]), isTrue);
    expect(named('Alexander Kim').text('notes'), 'from the roster');
    expect(named('Alex Kim').text('notes'), isEmpty);
    expect(named('Alex Kim').text('uscf_id'), isEmpty);
    expect(owner.players, hasLength(4));
  });

  test('an imported row keeps file links and aliases the person held in a '
      'form this app does not read', () async {
    await files.savePlayer(
      Player.create('Carla Diaz').edited({
        'uscf_id': '33333333',
        'pgn_files': '/home/u/opp.pgn',
        'aliases': ['Carla', 7],
      }),
    );
    await owner.load();
    final imported = Player.create('Carla Diaz').edited({
      'uscf_id': '33333333',
      'aliases': ['C. Diaz'],
    });
    expect(await owner.import([imported]), isTrue);
    final carla = named('Carla Diaz');
    expect(carla.fields['pgn_files'], ['/home/u/opp.pgn']);
    expect(carla.fields['aliases'], ['Carla', 7, 'C. Diaz']);
  });
}

/// [PlayerFiles] whose reads wait for [gate].
final class _Gated implements PlayerStore {
  _Gated(this.files, this.gate);
  final PlayerFiles files;
  final Future<void> gate;

  @override
  Future<PlayerDirectory> read() async {
    await gate;
    return files.read();
  }

  @override
  Future<void> savePlayer(Player player, {Player? expected}) =>
      files.savePlayer(player, expected: expected);
  @override
  Future<void> saveGroup(PlayerGroup group, {PlayerGroup? expected}) =>
      files.saveGroup(group, expected: expected);
  @override
  Future<void> removePlayer(Player player) => files.removePlayer(player);
  @override
  Future<void> removeGroup(PlayerGroup group) => files.removeGroup(group);
}

/// [PlayerFiles] whose next player save fails like a disk error.
final class _FailOnce implements PlayerStore {
  _FailOnce(this.files);
  final PlayerFiles files;
  bool failNext = false;

  /// What the failing save throws: the disk's own error for a full disk.
  Object failWith = FileSystemException(
    'Cannot write file',
    'player.json',
    OSError('No space left on device', Platform.isWindows ? 112 : 28),
  );

  /// Whether every read fails, as an unreadable folder does.
  bool failReads = false;

  @override
  Future<PlayerDirectory> read() async {
    if (failReads) {
      throw const FileSystemException('Cannot list', 'players');
    }
    return files.read();
  }

  @override
  Future<void> savePlayer(Player player, {Player? expected}) async {
    if (failNext) {
      failNext = false;
      throw failWith;
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
