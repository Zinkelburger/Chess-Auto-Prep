import 'dart:io';

import 'package:chess_auto_prep/utils/atomic_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late File target;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('atomic_file_safety_test');
    target = File(p.join(temp.path, 'chapter.pgn'));
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('normal replacement leaves one complete new file', () async {
    await target.writeAsString('old');
    await writeTextFileAtomically(target, 'new');

    expect(await target.readAsString(), 'new');
    expect(
      temp.listSync().whereType<File>().where(
        (f) => p.basename(f.path).contains('chapter.pgn.'),
      ),
      isEmpty,
    );
  });

  test('createOnly refuses to overwrite existing content', () async {
    await target.writeAsString('old');

    await expectLater(
      writeTextFileAtomically(target, 'new', createOnly: true),
      throwsA(isA<FileSystemException>()),
    );
    expect(await target.readAsString(), 'old');
  });

  test('concurrent create-only writers cannot overwrite the winner', () async {
    final newTarget = File(p.join(temp.path, 'new-study.pgn'));

    final results = await Future.wait(
      ['one', 'two', 'three'].map((value) async {
        try {
          await writeTextFileAtomically(newTarget, value, createOnly: true);
          return true;
        } on FileSystemException {
          return false;
        }
      }),
    );

    expect(results.where((succeeded) => succeeded), hasLength(1));
    expect(['one', 'two', 'three'], contains(await newTarget.readAsString()));
  });

  test('stale expected content cannot overwrite a newer edit', () async {
    await target.writeAsString('version one');
    const staleSnapshot = 'version one';
    await writeTextFileAtomically(target, 'version two');

    await expectLater(
      writeTextFileAtomically(
        target,
        'stale replacement',
        expectedContent: staleSnapshot,
      ),
      throwsA(isA<AtomicWriteConflict>()),
    );

    expect(await target.readAsString(), 'version two');
  });

  test('failed fallback install rolls the original back', () async {
    await target.writeAsString('old');
    final writer = AtomicFileWriter(
      forceBackupSwapForTesting: true,
      testHook: (step) async {
        if (step == AtomicWriteStep.beforeReplacementInstall) {
          throw const FileSystemException('injected install failure');
        }
      },
    );

    await expectLater(writer.writeText(target, 'new'), throwsException);
    expect(await target.readAsString(), 'old');
  });

  test('recovery restores an interrupted backup swap', () async {
    await target.writeAsString('old');
    final writer = AtomicFileWriter(
      forceBackupSwapForTesting: true,
      testHook: (step) async {
        if (step == AtomicWriteStep.backupInstalled) {
          throw const FileSystemException('simulated process death');
        }
      },
    );

    await expectLater(writer.writeText(target, 'new'), throwsException);
    expect(await target.exists(), isFalse);

    await recoverAtomicWritesInDirectory(temp);
    expect(await target.readAsString(), 'old');
    expect(
      temp.listSync().where(
        (e) => p.basename(e.path).startsWith('.cap-safe-write-'),
      ),
      isEmpty,
    );
  });

  test('recovery keeps a replacement installed before interruption', () async {
    await target.writeAsString('old');
    var injected = false;
    final writer = AtomicFileWriter(
      forceBackupSwapForTesting: true,
      testHook: (step) async {
        if (!injected && step == AtomicWriteStep.replacementInstalled) {
          injected = true;
          throw const FileSystemException('simulated process death');
        }
      },
    );

    await expectLater(writer.writeText(target, 'new'), throwsException);
    expect(await target.readAsString(), 'new');

    await recoverAtomicWritesInDirectory(temp);
    expect(await target.readAsString(), 'new');
  });

  test('concurrent appends never lose or partially write a batch', () async {
    await target.writeAsString('start\n');

    await Future.wait([
      appendTextFileAtomically(target, 'alpha\n'),
      appendTextFileAtomically(target, 'beta\n'),
      appendTextFileAtomically(target, 'gamma\n'),
    ]);

    final lines = (await target.readAsLines()).toSet();
    expect(lines, {'start', 'alpha', 'beta', 'gamma'});
  });
}
