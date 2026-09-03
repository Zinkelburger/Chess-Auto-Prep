import 'dart:io';

import 'package:chess_auto_prep/features/bughouse/services/bughouse_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Launching the engine from a path that is not absolute.
///
/// The app always has an absolute one — the support directory — so this is the
/// case only a local engine build and the tests ever hit, and it broke the
/// moment the process gained a working directory: POSIX changes directory
/// before it looks the executable up, so a relative path gets resolved a
/// second time inside the engine's own folder and is not there. Windows
/// resolves the executable against the parent's directory and ignores
/// workingDirectory, so it alone kept working — which is exactly the shape of
/// bug that reaches users on one platform only.
void main() {
  late Directory root;
  late String previousCwd;

  /// A stand-in engine: enough UCI to complete a handshake, and it prints its
  /// own working directory so the test can prove where it was started.
  Future<void> writeFakeEngine(String path) async {
    final file = File(path);
    await file.writeAsString('''
#!/bin/sh
echo "info string cwd \$PWD"
while read -r line; do
  case "\$line" in
    uci) echo "id name fake"; echo "uciok" ;;
    isready) echo "readyok" ;;
    quit) exit 0 ;;
  esac
done
''');
    await Process.run('chmod', ['+x', path]);
  }

  setUp(() async {
    previousCwd = Directory.current.path;
    root = await Directory.systemTemp.createTemp('bughouse-launch');
    final dir = await Directory(
      p.join(root.path, 'engine under test'),
    ).create();
    await writeFakeEngine(p.join(dir.path, 'hivemind'));
    await File(
      p.join(dir.path, 'hivemind.onnx'),
    ).writeAsString('not a network');
  });

  tearDown(() async {
    Directory.current = previousCwd;
    await root.delete(recursive: true);
  });

  test(
    'starts from a relative path, in a directory whose name has a space',
    () async {
      Directory.current = root.path;
      final engine = await BughouseEngine.launch(
        executablePath: p.join('engine under test', 'hivemind'),
        modelPath: p.join('engine under test', 'hivemind.onnx'),
        libraryPath: p.join('engine under test'),
        timeout: const Duration(seconds: 20),
      );
      addTearDown(engine.dispose);
      expect(engine.name, 'fake');
      // Resolved to an absolute path rather than kept as it was handed over, so
      // the failure report names a file someone can actually go and look at.
      expect(p.isAbsolute(engine.executablePath), isTrue);
      expect(p.isAbsolute(engine.modelPath), isTrue);
    },
    skip: Platform.isWindows ? 'needs a POSIX shell' : null,
  );

  test('starts from an absolute path too', () async {
    final engine = await BughouseEngine.launch(
      executablePath: p.join(root.path, 'engine under test', 'hivemind'),
      modelPath: p.join(root.path, 'engine under test', 'hivemind.onnx'),
      timeout: const Duration(seconds: 20),
    );
    addTearDown(engine.dispose);
    expect(engine.name, 'fake');
  }, skip: Platform.isWindows ? 'needs a POSIX shell' : null);

  test('a path that is not there is named, not left to the process', () async {
    await expectLater(
      BughouseEngine.launch(
        executablePath: p.join(root.path, 'nothing here'),
        modelPath: p.join(root.path, 'engine under test', 'hivemind.onnx'),
      ),
      throwsA(
        isA<BughouseEngineFailure>().having(
          (e) => e.message,
          'message',
          contains('Engine binary not found'),
        ),
      ),
    );
  });
}
