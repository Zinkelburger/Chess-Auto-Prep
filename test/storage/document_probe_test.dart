import 'dart:io';
import 'dart:typed_data';

import 'package:chess_auto_prep/storage/document_probe.dart';
import 'package:document_file_io/document_file_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('v2-document-probe-');
  });
  tearDown(() async {
    if (!Platform.isWindows) {
      await Process.run('chmod', ['-R', 'u+rwx', root.path]);
    }
    await root.delete(recursive: true);
  });

  String at(String name) => p.join(root.path, name);

  /// [probeDocument] of a path whose native observation is [planted], or
  /// whose observation throws when [planted] is an exception.
  Future<Probe> probeAnswered(Object planted) => runWithNativeCalls(
    <T>(NativeCall call, List<String> paths, Future<T> Function() real) =>
        planted is Exception
        ? Future<T>.error(planted)
        : Future<T>.value(planted as T),
    () => probeDocument(at('a.pgn')),
  );

  test('each native status is found, missing, lasting or passing', () async {
    expect(
      await probeAnswered(
        NativeFileObservation(
          status: 0,
          error: 0,
          identity: 'dev:ino',
          bytes: Uint8List.fromList([42]),
          sha256Hex: 'ab' * 32,
        ),
      ),
      isA<FileFound>().having((f) => f.identity, 'identity', 'dev:ino'),
    );
    expect(
      await probeAnswered(NativeFileObservation(status: 1, error: 2)),
      isA<FileMissing>(),
    );
    expect(
      await probeAnswered(NativeFileObservation(status: 2, error: 13)),
      isA<FileNotReadNow>(),
    );
    expect(
      await probeAnswered(NativeFileObservation(status: 3, error: 0)),
      isA<FileNotReadNow>(),
    );
    expect(
      await probeAnswered(NativeFileObservation(status: 4, error: 0)),
      isA<FileNotPlain>(),
    );
    expect(
      await probeAnswered(const FileSystemException('held', 'a.pgn')),
      isA<FileNotReadNow>(),
    );
  });

  test('both kinds are still unreadable, with a detail for the log', () async {
    for (final status in [2, 3, 4]) {
      final probe = await probeAnswered(
        NativeFileObservation(status: status, error: 5),
      );
      expect(probe, isA<FileUnreadable>());
      expect((probe as FileUnreadable).detail, isNotEmpty);
    }
  });

  test('a link is not a plain file', () async {
    await File(at('target.pgn')).writeAsString('*');
    await Link(at('a.pgn')).create(at('target.pgn'));
    expect(await probeDocument(at('a.pgn')), isA<FileNotPlain>());
  }, skip: Platform.isWindows ? 'links need privileges on Windows' : false);

  test(
    'a file this process may not read now is passing',
    () async {
      await File(at('a.pgn')).writeAsString('*');
      await Process.run('chmod', ['000', at('a.pgn')]);
      expect(await probeDocument(at('a.pgn')), isA<FileNotReadNow>());
    },
    skip: !Platform.isLinux || Platform.environment['USER'] == 'root'
        ? 'needs a Linux user without root'
        : false,
  );
}
