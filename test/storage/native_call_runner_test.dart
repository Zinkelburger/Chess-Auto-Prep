// The seam the fault harness uses to watch and fail native calls. Without a
// runner every call goes straight to the OS, which document_file_io_test
// checks; with one, each call is seen with its paths and can be answered for.
import 'dart:io';

import 'package:document_file_io/document_file_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Notes each call as `name path…`, relative to [root], then runs it.
NativeCallRunner recorder(List<String> seen, String root) =>
    <T>(NativeCall call, List<String> paths, Future<T> Function() real) {
      final names = paths.map((path) => p.relative(path, from: root));
      seen.add([call.name, ...names].join(' '));
      return real();
    };

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('v2-native-runner-');
  });
  tearDown(() => root.delete(recursive: true));

  String at(String name) => p.join(root.path, name);

  test('every call is seen in order with its paths, nested ones too', () async {
    await File(at('staged')).writeAsString('one');
    await File(at('b')).writeAsString('b');
    final seen = <String>[];
    await runWithNativeCalls(recorder(seen, root.path), () async {
      await observeFile(at('a'));
      await observeFileBatch([at('a'), at('b')]);
      await observeDirectory(root.path);
      await syncFile(at('staged'));
      await installNewFile(at('staged'), at('a'));
      await syncDirectory(root.path);
      await File(at('next')).writeAsString('two');
      await replaceFileContents(at('next'), at('a'));
      await movePathNoReplace(at('a'), at('c'));
    });
    expect(seen, [
      'observeFile a',
      'observeFileBatch a b',
      'observeDirectory .',
      'syncFile staged',
      'installNewFile staged a',
      'syncDirectory .',
      'replaceFile next a',
      // Only Windows observes the destination before replacing it.
      if (Platform.isWindows) 'observeFile a',
      'movePathNoReplace a c',
    ]);
    expect(await File(at('c')).readAsString(), 'two');
  });

  test('an observation the runner answers with reaches the caller', () async {
    final planted = NativeFileObservation(status: 3, error: 0);
    Future<T> answer<T>(
      NativeCall call,
      List<String> paths,
      Future<T> Function() real,
    ) async => (call == NativeCall.observeFile ? planted : [planted]) as T;
    await File(at('a')).writeAsString('on disk');
    final (single, batch) = await runWithNativeCalls(
      answer,
      () async =>
          (await observeFile(at('a')), await observeFileBatch([at('a')])),
    );
    expect(single, same(planted));
    expect(batch.single, same(planted));
  });

  test(
    'a failure the runner throws reaches the caller; nothing moves',
    () async {
      await File(at('staged')).writeAsString('new');
      Future<T> fail<T>(
        NativeCall call,
        List<String> paths,
        Future<T> Function() real,
      ) => throw FileSystemException(
        'Exclusive publication failed',
        paths.last,
        const OSError('Native publication', 28),
      );
      await expectLater(
        runWithNativeCalls(fail, () => installNewFile(at('staged'), at('a'))),
        throwsA(
          isA<FileSystemException>()
              .having((error) => error.path, 'path', at('a'))
              .having((error) => error.osError?.errorCode, 'errno', 28),
        ),
      );
      expect(await File(at('staged')).readAsString(), 'new');
      expect(await File(at('a')).exists(), isFalse);
    },
  );

  test('a runner is seen only by calls made inside its own zone', () async {
    final first = <String>[], second = <String>[];
    await Future.wait([
      runWithNativeCalls(
        recorder(first, root.path),
        () => observeFile(at('first')),
      ),
      runWithNativeCalls(
        recorder(second, root.path),
        () => observeFile(at('second')),
      ),
    ]);
    final outside = await observeFile(at('outside'));
    expect(outside.status, 1);
    expect(first, ['observeFile first']);
    expect(second, ['observeFile second']);
  });
}
