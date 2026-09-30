import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/storage/tournament_inbox.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  setUp(
    () async =>
        root = await Directory.systemTemp.createTemp('tournament-inbox-'),
  );
  tearDown(() => root.delete(recursive: true));
  Future<void> write(String id, {DateTime? at}) =>
      File(p.join(root.path, 'open_request.json')).writeAsString(
        jsonEncode({
          'tournamentId': id,
          'requestedAt': (at ?? DateTime.now()).toIso8601String(),
        }),
      );

  test('two app windows consume one request at most once', () async {
    await write('one');
    final results = await Future.wait(
      List.generate(8, (_) => TournamentInbox(root).takeRequest()),
    );
    expect(results.whereType<String>(), ['one']);
  });
  test(
    'claim consumes once and preserves a request replaced during read',
    () async {
      await write('first');
      final inbox = TournamentInbox(root, afterClaim: () => write('second'));
      expect(await inbox.takeRequest(), 'first');
      expect(await TournamentInbox(root).takeRequest(), 'second');
      expect(await inbox.takeRequest(), isNull);
      expect(await root.list().toList(), isEmpty);
    },
  );
  test(
    'stale, malformed and traversal requests are ignored without replay',
    () async {
      for (final id in ['', '..', '../outside', '/absolute', 'sub\\file']) {
        await write(id);
        expect(await TournamentInbox(root).takeRequest(), isNull);
      }
      await write(
        'old',
        at: DateTime.now().subtract(const Duration(hours: 25)),
      );
      expect(await TournamentInbox(root).takeRequest(), isNull);
      await File(
        p.join(root.path, 'open_request.json'),
      ).writeAsString('{broken');
      expect(await TournamentInbox(root).takeRequest(), isNull);
      expect(await root.list().toList(), isEmpty);
    },
  );
  test(
    'watch sees existing and newly created run folders, and cancels',
    () async {
      final existing = await Directory(p.join(root.path, 'existing')).create();
      var count = 0;
      final ready = Completer<void>();
      final sub = TournamentInbox(root).changes().listen((_) {
        count++;
        if (!ready.isCompleted) ready.complete();
      });
      await ready.future.timeout(const Duration(seconds: 3));
      final baseline = count;
      await File(p.join(existing.path, 'tournament.json')).writeAsString('{}');
      await _until(() => count > baseline);
      final added = await Directory(p.join(root.path, 'new')).create();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final before = count;
      await File(p.join(added.path, 'tournament.json')).writeAsString('{}');
      await _until(() => count > before);
      await sub.cancel();
      final stopped = count;
      await File(
        p.join(added.path, 'tournament.json'),
      ).writeAsString('{"done":true}');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(count, stopped);
    },
  );
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue);
}
