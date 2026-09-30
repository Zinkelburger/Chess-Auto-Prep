// The FaultyDisk core on the real atomic writer, journal reader and
// quarantine: what it records, what each fault leaves on disk, and that a
// write around it is caught. Nothing here asserts how a store should
// behave; later scenario tests do that with these pieces.
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/storage/atomic_write.dart';
import 'package:chess_auto_prep/storage/journal_records.dart';
import 'package:chess_auto_prep/storage/recovery_quarantine.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/faulty_disk/fault_plan.dart';
import '../../support/faulty_disk/faulty_disk.dart';
import '../../support/faulty_disk/io_trace.dart';

final _roots = <Directory>[];

Future<Directory> _root() async {
  final root = await Directory.systemTemp.createTemp('v2-faulty-disk-');
  _roots.add(root);
  await Directory(p.join(root.path, 'Documents')).create();
  await Directory(p.join(root.path, 'Support')).create();
  return root;
}

/// [command]'s trace on a fresh root that [seed] fills with plain dart:io,
/// checked to account for every change the command made.
Future<List<String>> _keysOf(
  Future<void> Function(String root) seed,
  Future<void> Function(String root) command,
) async {
  final root = await _root();
  await seed(root.path);
  final disk = FaultyDisk(root);
  final before = disk.snapshot();
  final run = await disk.run(const FaultPlan.none(), () => command(root.path));
  expect(run.end, isA<Returned<void>>());
  expect(untracedWrites(before, disk.snapshot(), run.trace), isEmpty);
  return [for (final op in run.trace) '${op.key}'];
}

/// The same keys on two fresh roots, and those are [expected].
Future<void> _expectStableTrace(
  Future<void> Function(String root) seed,
  Future<void> Function(String root) command,
  List<String> expected,
) async {
  final first = await _keysOf(seed, command);
  final second = await _keysOf(seed, command);
  expect(second, first);
  expect(first, expected);
}

Future<void> _noSeed(String root) async {}

Future<void> _seedDocument(String root) =>
    File(p.join(root, 'Documents', 'a.pgn')).writeAsString('old');

Future<void> _seedJournal(String root) async {
  final journal = Directory(p.join(root, 'Support', 'compound-writes'));
  await journal.create();
  await File(p.join(journal.path, 'ok.json')).writeAsString('{"a":1}');
  await File(p.join(journal.path, 'bad.json')).writeAsString('not json');
  await File(p.join(journal.path, '.ok.json.v2-tmp')).writeAsString('torn');
}

String _document(String root, [String name = 'a.pgn']) =>
    p.join(root, 'Documents', name);

/// Everything a handler above a crash might try on the way out in [docs],
/// including finishing [log], a sink opened before the crash; returns the
/// attempts the frozen disk refused.
Future<List<String>> _tidyUp(String docs, IOSink log) async {
  final attempts = <String, Future<Object?> Function()>{
    'sink': () {
      log.write('after');
      return log.close();
    },
    'delete': () => File(p.join(docs, 'old.pgn')).delete(),
    'write': () => File(p.join(docs, 'c.pgn')).writeAsString('c'),
    'mkdir': () => Directory(p.join(docs, 'x')).create(),
    'rename': () => File(p.join(docs, 'a.pgn')).rename(p.join(docs, 'b.pgn')),
    'read': () => File(p.join(docs, 'a.pgn')).readAsString(),
    'syncDir': () => syncDirectory(docs),
  };
  final refused = <String>[];
  for (final MapEntry(:key, :value) in attempts.entries) {
    try {
      await value();
    } on SimulatedCrash {
      refused.add(key);
    }
  }
  return refused;
}

const _publishNew = OpKey(
  IoKind.publishNew,
  'Documents/.a.pgn.v2-tmp',
  to: 'Documents/a.pgn',
);

const _publishReplace = OpKey(
  IoKind.publishReplace,
  'Documents/.a.pgn.v2-tmp',
  to: 'Documents/a.pgn',
);

void main() {
  tearDownAll(() async {
    for (final root in _roots) {
      await root.delete(recursive: true);
    }
  });

  group('traces have the expected keys, the same on every run', () {
    test('createFileExclusively', () async {
      await _expectStableTrace(
        _noSeed,
        (root) => createFileExclusively(_document(root), utf8.encode('new')),
        [
          'create:Documents/.a.pgn.v2-tmp#0',
          'write:Documents/.a.pgn.v2-tmp#0',
          'sync:Documents/.a.pgn.v2-tmp#0',
          'publishNew:Documents/.a.pgn.v2-tmp->Documents/a.pgn#0',
          if (!Platform.isWindows) 'syncDir:Documents#0',
        ],
      );
    });

    test('replaceFile', () async {
      await _expectStableTrace(
        _seedDocument,
        (root) => replaceFile(_document(root), utf8.encode('new')),
        [
          'create:Documents/.a.pgn.v2-tmp#0',
          'write:Documents/.a.pgn.v2-tmp#0',
          'sync:Documents/.a.pgn.v2-tmp#0',
          'publishReplace:Documents/.a.pgn.v2-tmp->Documents/a.pgn#0',
          // Only Windows observes the destination before replacing it.
          if (Platform.isWindows) 'read:Documents/a.pgn#0',
          if (!Platform.isWindows) 'syncDir:Documents#0',
        ],
      );
    });

    test('readJournal, which quarantines a damaged record', () async {
      await _expectStableTrace(
        _seedJournal,
        (root) => readJournal(
          Directory(p.join(root, 'Support', 'compound-writes')),
          decode: (value, id) => value,
        ),
        [
          'stat:Support/compound-writes#0',
          'list:Support/compound-writes#0',
          'delete:Support/compound-writes/.ok.json.v2-tmp#0',
          'read:Support/compound-writes/bad.json#0',
          'mkdir:Support/recovery-quarantine/<time>#0',
          'rename:Support/compound-writes/bad.json'
              '->Support/recovery-quarantine/<time>/compound-writes-bad.json#0',
          'read:Support/compound-writes/ok.json#0',
        ],
      );
    });

    test('quarantine', () async {
      await _expectStableTrace(
        _seedJournal,
        (root) => quarantine(
          Directory(p.join(root, 'Support')),
          File(p.join(root, 'Support', 'compound-writes', 'ok.json')),
          'unreadable',
        ),
        [
          'mkdir:Support/recovery-quarantine/<time>#0',
          'rename:Support/compound-writes/ok.json'
              '->Support/recovery-quarantine/<time>/compound-writes-ok.json#0',
        ],
      );
    });
  });

  test(
    'CrashMidway on publishNew leaves two names, which observeFile refuses',
    () async {
      final root = await _root();
      final run = await FaultyDisk(root).run(
        const FaultPlan.at(_publishNew, CrashMidway()),
        () => createFileExclusively(_document(root.path), utf8.encode('new')),
      );
      expect(
        run.end,
        isA<Crashed<void>>().having((e) => e.at, 'at', _publishNew),
      );
      final staged = temporaryPathFor(_document(root.path));
      expect(await File(staged).readAsString(), 'new');
      expect(await File(_document(root.path)).readAsString(), 'new');
      expect((await observeFile(_document(root.path))).status, 4);
    },
    skip: Platform.isWindows ? 'link(2) is POSIX' : false,
  );

  test('after a crash, handlers cannot change the disk', () async {
    final root = await _root();
    final docs = p.join(root.path, 'Documents');
    await File(p.join(docs, 'old.pgn')).writeAsString('old');
    final disk = FaultyDisk(root);
    final refused = <String>[];
    final run = await disk.run(
      const FaultPlan.at(_publishNew, CrashAfter()),
      () async {
        final log = File(p.join(docs, 'log.txt')).openWrite()..write('before');
        await log.flush();
        try {
          await createFileExclusively(_document(root.path), utf8.encode('new'));
        } on SimulatedCrash {
          refused.addAll(await _tidyUp(docs, log));
        }
        return 'the command swallowed the crash';
      },
    );
    expect(run.end, isA<Crashed<String>>());
    expect(refused, [
      'sink',
      'delete',
      'write',
      'mkdir',
      'rename',
      'read',
      'syncDir',
    ]);
    expect(disk.snapshot(), run.atCrash);
    expect(disk.snapshot().entries.keys, [
      'Documents',
      'Documents/a.pgn',
      'Documents/log.txt',
      'Documents/old.pgn',
      'Support',
    ]);
    expect(await File(p.join(docs, 'log.txt')).readAsString(), 'before');
  });

  test('FailAfter on publishReplace leaves the new bytes and throws the '
      "adapter's error", () async {
    final root = await _root();
    await _seedDocument(root.path);
    final run = await FaultyDisk(root).run(
      const FaultPlan.at(_publishReplace, FailAfter(IoError.eio)),
      () => replaceFile(_document(root.path), utf8.encode('new')),
    );
    final error = (run.end as Threw<void>).error;
    expect(
      error,
      isA<FileSystemException>()
          .having((e) => e.path, 'path', _document(root.path))
          .having((e) => e.message, 'message', startsWith('File replacement'))
          .having((e) => e.osError?.errorCode, 'errno', IoError.eio.errno),
    );
    expect(await File(_document(root.path)).readAsString(), 'new');
  });

  test('FailBefore answers as the adapter or dart:io would', () async {
    final root = await _root();
    await _seedDocument(root.path);
    final path = _document(root.path);
    Future<RunEnd<T>> failing<T>(Fault fault, Future<T> Function() body) async {
      final plan = FaultPlan.where((op) => op.kind == IoKind.read, fault);
      return (await FaultyDisk(root).run(plan, body)).end;
    }

    Future<int> status(IoError error) async {
      final end = await failing(FailBefore(error), () => observeFile(path));
      return (end as Returned<NativeFileObservation>).value.status;
    }

    expect(await status(IoError.spuriousMissing), 1);
    expect(await status(IoError.eio), 2);
    expect(await status(IoError.changedWhileRead), 3);
    final missing = await failing(
      const FailBefore(IoError.spuriousMissing),
      () => File(path).readAsString(),
    );
    expect((missing as Threw<String>).error, isA<PathNotFoundException>());
    final denied = await failing(
      const FailBefore(IoError.eacces),
      () => File(path).readAsString(),
    );
    expect(
      (denied as Threw<String>).error,
      isA<PathAccessException>().having(
        (e) => e.osError?.errorCode,
        'errno',
        IoError.eacces.errno,
      ),
    );
    final third = await failing(
      const FailBefore(IoError.eio, times: 2),
      () async {
        for (var i = 0; i < 2; i++) {
          await expectLater(
            File(path).readAsString(),
            throwsA(isA<FileSystemException>()),
          );
        }
        return File(path).readAsString();
      },
    );
    expect((third as Returned<String>).value, 'old');
  });

  test(
    'CrashMidway tears a write and stops a recursive mkdir part way',
    () async {
      final root = await _root();
      final disk = FaultyDisk(root);
      final torn = await disk.run(
        FaultPlan.where((op) => op.kind == IoKind.write, const CrashMidway()),
        () => File(_document(root.path)).writeAsString('0123456789'),
      );
      expect(torn.end, isA<Crashed<File>>());
      expect(await File(_document(root.path)).readAsString(), '01234');
      final deep = p.join(root.path, 'Support', 'a', 'b', 'c');
      final partial = await disk.run(
        FaultPlan.where((op) => op.kind == IoKind.mkdir, const CrashMidway()),
        () => Directory(deep).create(recursive: true),
      );
      expect(partial.end, isA<Crashed<Directory>>());
      expect(
        await Directory(p.join(root.path, 'Support', 'a')).exists(),
        isTrue,
      );
      expect(
        await Directory(p.join(root.path, 'Support', 'a', 'b')).exists(),
        isFalse,
      );
    },
  );

  test('a pause holds the call; a run past its limit hangs', () async {
    final root = await _root();
    final disk = FaultyDisk(root);
    const create = OpKey(IoKind.create, 'Documents/.a.pgn.v2-tmp');
    final held = Pause();
    final running = disk.run(
      FaultPlan.at(create, held),
      () => createFileExclusively(_document(root.path), utf8.encode('new')),
    );
    await held.reached;
    expect(
      await File(temporaryPathFor(_document(root.path))).exists(),
      isFalse,
    );
    held.release();
    expect((await running).end, isA<Returned<void>>());

    final stuck = Pause();
    final hung = await disk.run(
      FaultPlan.at(
        const OpKey(IoKind.create, 'Documents/.b.pgn.v2-tmp'),
        stuck,
      ),
      () => createFileExclusively(_document(root.path, 'b.pgn'), [1]),
      limit: const Duration(milliseconds: 100),
    );
    stuck.release();
    expect(
      hung.end,
      isA<Hung<void>>().having(
        (e) => '${e.at}',
        'at',
        'create:Documents/.b.pgn.v2-tmp#0',
      ),
    );
    expect(hung.atCrash!.entries.keys, isNot(contains('Documents/b.pgn')));
  });

  test('a File built outside the run is an untraced write, even in a '
      'folder the run wrote to or made', () async {
    final root = await _root();
    final disk = FaultyDisk(root);
    final before = disk.snapshot();
    final made = p.join(root.path, 'Support', 'made');
    final strays = [
      File(p.join(root.path, 'Support', 'stray.json')),
      // Beside the published file, in the folder the run synced.
      File(_document(root.path, 'stray.pgn')),
      File(p.join(made, 'stray.json')),
    ];
    final run = await disk.run(const FaultPlan.none(), () async {
      await createFileExclusively(_document(root.path), utf8.encode('new'));
      await Directory(made).create();
      for (final stray in strays) {
        await stray.writeAsString('{}');
      }
    });
    expect(run.end, isA<Returned<void>>());
    expect(untracedWrites(before, disk.snapshot(), run.trace), [
      'Documents/stray.pgn',
      'Support/made/stray.json',
      'Support/stray.json',
    ]);
  });
}
