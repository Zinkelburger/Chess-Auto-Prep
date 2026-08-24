import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/features/engine_tournament/services/tournament_open_request.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/tournament_open_watcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late TournamentOpenRequests requests;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('open_request_test');
    requests = TournamentOpenRequests(temp);
  });

  tearDown(() async {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('the request file', () {
    test('round-trips an id', () async {
      await requests.write('my-match');
      final taken = await requests.take();
      expect(taken?.tournamentId, 'my-match');
    });

    test('is consumed by reading, so it cannot re-fire', () async {
      await requests.write('my-match');
      expect((await requests.take())?.tournamentId, 'my-match');
      expect(await requests.take(), isNull);
      expect(requests.file.existsSync(), isFalse);
    });

    test('is nothing when there is no file', () async {
      expect(await requests.take(), isNull);
    });

    test('a malformed file is dropped rather than retried', () async {
      requests.file.writeAsStringSync('{ not json');
      expect(await requests.take(), isNull);
      expect(requests.file.existsSync(), isFalse);
    });

    test('a request with no id is not a request', () async {
      requests.file.writeAsStringSync(
        jsonEncode({'requestedAt': '2026-01-01'}),
      );
      expect(await requests.take(), isNull);
    });

    test('a stale request does not hijack an unrelated launch', () async {
      requests.file.writeAsStringSync(
        jsonEncode({
          'tournamentId': 'ancient',
          'requestedAt': DateTime(2026, 1, 1).toIso8601String(),
        }),
      );
      expect(await requests.take(now: DateTime(2026, 8, 22)), isNull);
      // Still cleared, so it cannot linger and be re-evaluated.
      expect(requests.file.existsSync(), isFalse);
    });

    test('a request written moments ago is honoured', () async {
      await requests.write('fresh');
      final taken = await requests.take(
        now: DateTime.now().add(const Duration(minutes: 5)),
      );
      expect(taken?.tournamentId, 'fresh');
    });

    test('a clock that runs backwards does not lose the request', () async {
      await requests.write('fresh');
      final taken = await requests.take(
        now: DateTime.now().subtract(const Duration(hours: 3)),
      );
      expect(taken?.tournamentId, 'fresh');
    });

    test('the written file is what the MCP side agrees to write', () async {
      await requests.write('my-match');
      final json =
          jsonDecode(requests.file.readAsStringSync()) as Map<String, dynamic>;
      expect(json.keys, containsAll(['tournamentId', 'requestedAt']));
      expect(json['tournamentId'], 'my-match');
      expect(DateTime.tryParse(json['requestedAt'] as String), isNotNull);
    });

    test('the directory is created on demand', () async {
      final nested = Directory(p.join(temp.path, 'a', 'b'));
      await TournamentOpenRequests(nested).write('deep');
      expect(nested.existsSync(), isTrue);
    });
  });

  group('the watcher', () {
    test('delivers a request that was already waiting', () async {
      await requests.write('waiting');
      final seen = <String>[];
      final watcher = TournamentOpenWatcher(
        directory: temp,
        onRequest: seen.add,
      );
      await watcher.start();
      await watcher.stop();
      expect(seen, ['waiting']);
    });

    test('delivers a request written while it is running', () async {
      final seen = <String>[];
      final watcher = TournamentOpenWatcher(
        directory: temp,
        onRequest: seen.add,
      );
      await watcher.start();
      addTearDown(watcher.stop);

      await requests.write('live');
      // The watch is asynchronous; give it a moment, then fall back to the
      // explicit check that the app also uses on resume.
      for (var i = 0; i < 20 && seen.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (seen.isEmpty) await watcher.check();
      expect(seen, ['live']);
    });

    test('delivers nothing when there is nothing', () async {
      final seen = <String>[];
      final watcher = TournamentOpenWatcher(
        directory: temp,
        onRequest: seen.add,
      );
      await watcher.start();
      await watcher.check();
      await watcher.stop();
      expect(seen, isEmpty);
    });

    test('a missing directory is created, not fatal', () async {
      final missing = Directory(p.join(temp.path, 'not-yet'));
      final watcher = TournamentOpenWatcher(
        directory: missing,
        onRequest: (_) {},
      );
      await watcher.start();
      addTearDown(watcher.stop);
      expect(missing.existsSync(), isTrue);
    });

    test('stops delivering once stopped', () async {
      final seen = <String>[];
      final watcher = TournamentOpenWatcher(
        directory: temp,
        onRequest: seen.add,
      );
      await watcher.start();
      await watcher.stop();
      await requests.write('too-late');
      await watcher.check();
      expect(seen, isEmpty);
    });
  });
}
