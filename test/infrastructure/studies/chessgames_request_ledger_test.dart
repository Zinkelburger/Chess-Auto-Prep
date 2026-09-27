import 'dart:io';

import 'package:chess_auto_prep/infrastructure/studies/chessgames_request_ledger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late DateTime now;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('chessgames_ledger');
    now = DateTime(2026, 9, 27, 12);
  });
  tearDown(() => root.delete(recursive: true));

  ChessgamesRequestLedger ledger() => ChessgamesRequestLedger(
    () async => File(p.join(root.path, 'ledger.json')),
    clock: () => now,
  );

  test('spaces requests by the minimum gap, across instances', () async {
    expect(await ledger().reserve(), Duration.zero);
    now = now.add(const Duration(seconds: 5));
    expect(await ledger().reserve(), const Duration(seconds: 15));
    now = now.add(const Duration(seconds: 15));
    expect(await ledger().reserve(), Duration.zero);
  });

  test(
    'refuses past the daily limit until the oldest request ages out',
    () async {
      final l = ledger();
      final start = now;
      for (var i = 0; i < ChessgamesRequestLedger.dailyLimit; i++) {
        expect(await l.reserve(), Duration.zero);
        now = now.add(ChessgamesRequestLedger.minGap);
      }
      final wait = await l.reserve();
      expect(now.add(wait), start.add(ChessgamesRequestLedger.window));
      now = now.add(wait);
      expect(await l.reserve(), Duration.zero);
    },
  );

  test('a ban blocks every request for the cooldown', () async {
    await ledger().recordBan();
    now = now.add(const Duration(hours: 1));
    expect(
      await ledger().reserve(),
      ChessgamesRequestLedger.banCooldown - const Duration(hours: 1),
    );
    now = now.add(ChessgamesRequestLedger.banCooldown);
    expect(await ledger().reserve(), Duration.zero);
  });

  test('an unreadable ledger starts fresh', () async {
    await File(p.join(root.path, 'ledger.json')).writeAsString('{not json');
    expect(await ledger().reserve(), Duration.zero);
  });
}
