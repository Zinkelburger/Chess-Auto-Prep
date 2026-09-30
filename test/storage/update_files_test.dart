import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/storage/update_files.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const bytes = [1, 2, 3, 4, 5];
final ExpectedPayload expected = (
  tag: 'v1.17.0',
  name: 'chess-auto-prep-v1.17.0-linux.zip',
  size: bytes.length,
  sha256: '${sha256.convert(bytes)}',
);

void main() {
  late Directory root;
  late UpdateFolder folder;
  final never = Completer<void>().future;

  setUp(() {
    root = Directory.systemTemp.createTempSync('update-files-');
    folder = UpdateFolder(Directory(p.join(root.path, 'updates')));
  });
  tearDown(() => root.deleteSync(recursive: true));

  List<String> files() => root
      .listSync(recursive: true)
      .whereType<File>()
      .map((f) => p.basename(f.path))
      .toList();

  Future<Received> receive(
    List<List<int>> chunks, {
    int? announced,
    Future<void>? stop,
  }) => folder.receive(
    expected,
    Stream.fromIterable(chunks),
    announced: announced,
    progress: (_) {},
    stop: stop ?? never,
  );

  test('a file that matches size and SHA-256 takes its real name', () async {
    final seen = <int>[];
    final received = await folder.receive(
      expected,
      Stream.fromIterable([
        [1, 2],
        [3, 4, 5],
      ]),
      progress: seen.add,
      stop: never,
    );
    final payload = (received as Verified).payload;
    expect(File(payload.path).readAsBytesSync(), bytes);
    expect(p.basename(payload.path), expected.name);
    expect(seen, [2, 5]);
    expect(files(), [expected.name]);
  });

  test('corrupt, short, long and misannounced downloads are refused and '
      'removed', () async {
    final cases = <(List<List<int>>, int?, Refusal)>[
      (
        [
          [5, 4, 3, 2, 1],
        ],
        null,
        Refusal.checksum,
      ),
      (
        [
          [1, 2, 3],
        ],
        null,
        Refusal.sizeMismatch,
      ),
      (
        [
          [1, 2, 3, 4, 5, 6],
        ],
        null,
        Refusal.tooLarge,
      ),
      ([bytes], 9, Refusal.sizeMismatch),
    ];
    for (final (chunks, announced, refusal) in cases) {
      final received = await receive(chunks, announced: announced);
      expect((received as Refused).refusal, refusal);
      expect(files(), isEmpty, reason: '$refusal');
    }
  });

  test('cancelling a stalled transfer stops it and leaves nothing', () async {
    final stalled = StreamController<List<int>>();
    final stop = Completer<void>();
    final receiving = folder.receive(
      expected,
      stalled.stream,
      progress: (_) {},
      stop: stop.future,
    );
    stalled.add([1, 2]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    stop.complete();
    expect(await receiving, isA<ReceiveCancelled>());
    expect(files(), isEmpty);
    await stalled.close();
  });

  test('a transfer that breaks off is a failure and leaves nothing', () async {
    final received = await folder.receive(
      expected,
      Stream.error(TimeoutException('stalled')),
      progress: (_) {},
      stop: never,
    );
    expect(received, isA<ReceiveFailed>());
    expect(files(), isEmpty);
  });

  test('a verified file is found again after a restart, a damaged one is '
      'not', () async {
    final payload = ((await receive([bytes])) as Verified).payload;
    final again = await UpdateFolder(folder.root).verified(expected);
    expect(again!.path, payload.path);
    File(payload.path).writeAsBytesSync([9, 9, 9, 9, 9]);
    expect(await folder.verified(expected), isNull);
  });

  group('pruning', () {
    final old = DateTime.now().subtract(const Duration(hours: 1));

    /// An attempt folder holding [files]; each written [at], else now.
    Directory attempt(String name, List<String> files, {DateTime? at}) {
      final folder = Directory(p.join(root.path, 'updates', name))
        ..createSync(recursive: true);
      for (final file in files) {
        final written = File(p.join(folder.path, file))..writeAsStringSync('x');
        if (at != null) written.setLastModifiedSync(at);
      }
      return folder;
    }

    test('removes older attempts nothing uses', () async {
      final older = attempt('v1.16.0-a', ['old.zip']);
      final payload = ((await receive([bytes])) as Verified).payload;
      await folder.prune(keep: payload, helperRunning: false);
      expect(older.existsSync(), isFalse);
      expect(File(payload.path).existsSync(), isTrue);
    });

    test('leaves a live attempt alone: another copy downloading or '
        'arming, or a helper waiting', () async {
      final downloading = attempt('v1.17.0-b', ['${expected.name}.part']);
      final arming = attempt('v1.17.0-c', [armedName]);
      final waiting = attempt('v1.17.0-d', [
        armedName,
        helperReadyName,
      ], at: old);
      final payload = ((await receive([bytes])) as Verified).payload;
      await folder.prune(keep: payload, helperRunning: true);
      expect(downloading.existsSync(), isTrue);
      expect(arming.existsSync(), isTrue);
      expect(waiting.existsSync(), isTrue);
    });

    test('removes what a killed helper or a stalled download left', () async {
      final killed = attempt('v1.17.0-e', [
        armedName,
        helperReadyName,
      ], at: old);
      final stalled = attempt('v1.17.0-f', ['${expected.name}.part'], at: old);
      final payload = ((await receive([bytes])) as Verified).payload;
      await folder.prune(keep: payload, helperRunning: false);
      expect(killed.existsSync(), isFalse);
      expect(stalled.existsSync(), isFalse);
    });
  });

  test("a failed install's report is read at one start only", () async {
    expect(await folder.takeFailedInstall(), isNull);
    folder.root.createSync(recursive: true);
    File(
      p.join(folder.root.path, 'last-error.txt'),
    ).writeAsStringSync('Update installation failed (exit 1).\n');
    final failed = await folder.takeFailedInstall();
    expect(failed!.report, 'Update installation failed (exit 1).');
    expect(failed.folder, folder.root.path);
    expect(await folder.takeFailedInstall(), isNull);
  });

  test(
    "a failed install's log folder is the attempt the report names",
    () async {
      final attempt = Directory(p.join(folder.root.path, 'v1.17.0-a'))
        ..createSync(recursive: true);
      final log = p.join(attempt.path, 'install.log');
      File(p.join(folder.root.path, 'last-error.txt')).writeAsStringSync(
        'Update installation failed (exit 1). Details: $log\n',
      );
      expect((await folder.takeFailedInstall())!.folder, attempt.path);

      final outside = p.join(root.path, 'elsewhere', 'install.log');
      File(
        p.join(folder.root.path, 'last-error.txt'),
      ).writeAsStringSync('Update installation failed: x. Details: $outside');
      expect(
        (await folder.takeFailedInstall())!.folder,
        folder.root.path,
        reason: 'only one of ours is shown',
      );
    },
  );
}
