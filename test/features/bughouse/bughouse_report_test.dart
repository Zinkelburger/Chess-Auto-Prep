import 'dart:io';

import 'package:chess_auto_prep/app_version.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_bundle.dart';
import 'package:chess_auto_prep/features/bughouse/services/bughouse_engine.dart';
import 'package:chess_auto_prep/features/bughouse/services/windows_loader_check.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The report a user copies out of the failure banner.
///
/// Asserted rather than left to be seen only when something breaks, because
/// the whole point of it is that the person who hits the failure does not have
/// to understand it — so every fact whoever *does* have to understand it will
/// ask for has to already be in the text.
void main() {
  group('formatReport', () {
    String report({
      String headline = 'Engine did not answer "uci" within 90s',
      int? exitCode = -1073741701,
      bool spoke = false,
      List<String> directory = const [],
      List<DllResolution>? libraries,
      List<String> stdout = const [],
      List<String> stderr = const [],
      String? loaderPath,
      ContentVerification? integrity,
    }) => BughouseEngine.formatReport(
      headline: headline,
      integrity: integrity,
      executablePath: r'C:\support\bughouse\hivemind-windows.exe',
      argv: const ['--model', 'hivemind.onnx'],
      workingDirectory: r'C:\support\bughouse',
      exitCode: exitCode,
      spoke: spoke,
      directory: directory,
      libraries: libraries,
      stdout: stdout,
      stderr: stderr,
      loaderPath: loaderPath,
    );

    test('names the build, or a bug report is about an unknown version', () {
      expect(report(), contains(kAppVersion));
    });

    /// The section that exists because every other one can read clean while
    /// the engine still will not start: a file of the right length holding the
    /// wrong bytes keeps a parseable PE header, so it is listed at the right
    /// size and the right architecture and is still what Windows refused.
    group('the content check', () {
      test('is absent when there was nothing to compare', () {
        expect(report(), isNot(contains('File integrity and repair')));
      });

      test('says so plainly when every file is the one we shipped', () {
        final text = report(
          integrity: const ContentVerification(
            lines: [
              '  onnxruntime.dll             matches the copy inside '
                  'this build',
            ],
            damaged: [],
          ),
        );
        expect(text, contains('File integrity and repair'));
        expect(text, contains('matches the copy inside this build'));
        // Nothing was wrong, so nothing is claimed to have been repaired.
        expect(text, isNot(contains('!!')));
      });

      test('names the mismatch without claiming a successful repair', () {
        final text = report(
          integrity: const ContentVerification(
            lines: [
              '  onnxruntime.dll             DOES NOT MATCH the copy '
                  'inside this build',
            ],
            damaged: ['onnxruntime.dll'],
          ),
        );
        expect(text, contains('DOES NOT MATCH'));
        expect(text, contains('!!'));
        expect(text, contains('File mismatch: onnxruntime.dll'));
        expect(text, contains('Open Bughouse Lab again'));
      });
    });

    group('ContentVerification.repairedMessage', () {
      test('is null when nothing is damaged', () {
        expect(
          const ContentVerification(lines: ['x'], damaged: []).repairedMessage,
          isNull,
        );
      });

      test('lists every mismatched file', () {
        final message = const ContentVerification(
          lines: [],
          damaged: ['onnxruntime.dll', 'hivemind.onnx'],
        ).repairedMessage;
        expect(
          message,
          contains('File mismatch: onnxruntime.dll, hivemind.onnx'),
        );
      });
    });

    test('carries the exact command and where it ran', () {
      final text = report();
      expect(text, contains('["--model","hivemind.onnx"]'));
      expect(text, contains(r'C:\support\bughouse'));
      expect(text, contains(r'hivemind-windows.exe'));
    });

    test('decodes the exit code rather than only printing it', () {
      final text = report();
      expect(text, contains('-1073741701'));
      expect(text, contains('0xC000007B; STATUS_INVALID_IMAGE_FORMAT'));
    });

    /// "It printed nothing" and "it printed something and then stopped" are
    /// different failures with different causes, and the difference is
    /// invisible unless the report states it.
    test('says whether the engine ever spoke', () {
      expect(report(spoke: false), contains('no stdout received'));
      expect(report(spoke: true), contains('stdout received'));
    });

    test('an engine not observed when it was given up on says so', () {
      expect(report(exitCode: null), contains('not observed'));
    });

    test('quotes the engine when the engine said why', () {
      expect(
        report(stderr: const ['Error: ONNX model not found: /x.onnx']),
        contains('ONNX model not found'),
      );
    });

    /// Silence on both streams is itself the finding — it means the process
    /// was stopped before it ran any of its own code.
    test('empty streams are reported as a finding, not as blank', () {
      expect(report(), contains('(empty)'));
    });

    test('the Windows section is absent off Windows', () {
      expect(report(), isNot(contains('DLL candidates')));
    });

    test('a shadowed library is named with its path and its architecture', () {
      final text = report(
        libraries: const [
          DllResolution(
            name: 'MSVCP140.dll',
            path: r'C:\Toolchain\MSVCP140.dll',
            machine: 0x014c,
          ),
        ],
      );
      expect(text, contains('DLL candidates'));
      expect(text, contains(r'C:\Toolchain\MSVCP140.dll'));
      expect(text, contains('32-bit'));
      // The verdict, not just the table.
      expect(text, contains('!! '));
    });

    test('the loader variable is shown where there is one', () {
      expect(
        report(loaderPath: 'LD_LIBRARY_PATH=/tmp/bughouse'),
        contains('LD_LIBRARY_PATH=/tmp/bughouse'),
      );
    });
  });

  group('failure evidence collection', () {
    late Directory directory;
    setUp(
      () async =>
          directory = await Directory.systemTemp.createTemp('bughouse-report-'),
    );
    tearDown(() async => directory.delete(recursive: true));

    test(
      'failed integrity check keeps paths, raw output and the end marker',
      () async {
        final payload = File(p.join(directory.path, 'engine.bin'));
        await payload.writeAsBytes([1, 2, 3]);
        final report = await BughouseEngine.collectReport(
          headline: 'original startup error',
          executablePath: payload.path,
          argv: ['--model', 'model with spaces.onnx'],
          workingDirectory: directory.path,
          environment: {},
          exitCode: -1073741701,
          spoke: false,
          stdout: [],
          stderr: ['raw loader error'],
          verifyIntegrity: () async =>
              throw const FileSystemException('read denied'),
        );
        expect(report, contains('original startup error'));
        expect(report, contains('engine.bin'));
        expect(report, contains('3 bytes'));
        expect(
          report,
          contains('Integrity check failed: FileSystemException: read denied'),
        );
        expect(report, contains('raw loader error'));
        expect(report, endsWith('END BUGHOUSE DIAGNOSTICS'));
      },
    );

    test('file evidence is captured before repair removes the file', () async {
      final payload = File(p.join(directory.path, 'damaged.dll'));
      await payload.writeAsBytes([1, 2, 3]);
      final report = await BughouseEngine.collectReport(
        headline: 'startup error',
        executablePath: payload.path,
        argv: [],
        workingDirectory: directory.path,
        environment: {},
        exitCode: -1073741701,
        spoke: false,
        stdout: [],
        stderr: [],
        verifyIntegrity: () async {
          await payload.delete();
          return const ContentVerification(
            lines: ['damaged.dll: removed'],
            damaged: ['damaged.dll'],
          );
        },
      );
      expect(await payload.exists(), isFalse);
      expect(report, contains('3 bytes'));
      expect(report, contains('damaged.dll: removed'));
      expect(report, isNot(contains('has been replaced')));
    });

    test(
      'Process.start failure includes the original OS error and a report',
      () async {
        final model = File(p.join(directory.path, 'model.onnx'));
        await model.writeAsBytes([1]);
        try {
          await BughouseEngine.launch(
            executablePath: p.join(directory.path, 'missing-engine'),
            modelPath: model.path,
          );
          fail('expected launch failure');
        } on BughouseEngineFailure catch (e) {
          expect(e.message, contains('ProcessException'));
          expect(e.report, contains('not started'));
          expect(e.report, contains('missing-engine'));
          expect(e.report, contains('model.onnx'));
          expect(e.report, endsWith('END BUGHOUSE DIAGNOSTICS'));
        }
      },
    );
  });

  group('modelArgument', () {
    /// The support directory is `…\com.example\Chess Auto Prep\bughouse`, and
    /// no path this feature has ever been tested against has a space in it —
    /// so an absolute path is the one argument whose survival through a
    /// Windows command line nothing checks. A bare filename cannot be split.
    test('is the bare filename when the network sits beside the engine', () {
      expect(
        BughouseEngine.modelArgument(
          p.join('/a', 'Chess Auto Prep', 'hivemind.onnx'),
          p.join('/a', 'Chess Auto Prep'),
        ),
        'hivemind.onnx',
      );
    });

    test('stays a full path when it does not', () {
      final elsewhere = p.join('/other', 'net.onnx');
      expect(BughouseEngine.modelArgument(elsewhere, '/a/engine'), elsewhere);
    });
  });

  group('verifyExtraction', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('bughouse-extract');
    });
    tearDown(() async => dir.delete(recursive: true));

    Future<void> write(String name, int bytes) =>
        File(p.join(dir.path, name)).writeAsBytes(List.filled(bytes, 0));

    test(
      'an extraction that matches the manifest has nothing to say',
      () async {
        for (final name in BughouseBundle.installedFileNames) {
          await write(name, 10);
        }
        final manifest = {
          for (final name in BughouseBundle.installedFileNames) name: 10,
        };
        expect(
          await BughouseBundle.verifyExtraction(dir.path, manifest),
          isEmpty,
        );
      },
    );

    /// The failure this exists for: Windows keeps its own onnxruntime.dll in
    /// System32, so an engine whose copy is short does not fail to find a
    /// runtime — it finds the wrong one.
    test('a short file is named, with both sizes', () async {
      for (final name in BughouseBundle.installedFileNames) {
        await write(name, 4);
      }
      final manifest = {
        for (final name in BughouseBundle.installedFileNames) name: 10,
      };
      final problems = await BughouseBundle.verifyExtraction(
        dir.path,
        manifest,
      );
      expect(problems, hasLength(3));
      expect(problems.first, contains('4 bytes'));
      expect(problems.first, contains('10'));
      expect(problems.first, contains('did not finish'));
    });

    test('a missing file is named as missing', () async {
      final manifest = {BughouseBundle.installedFileNames.first: 10};
      final problems = await BughouseBundle.verifyExtraction(
        dir.path,
        manifest,
      );
      expect(problems.single, contains('is missing'));
    });

    test('a corrupt file with the right size is rejected by SHA-256', () async {
      final name = BughouseBundle.installedFileNames.first;
      await write(name, 10);
      final problems = await BughouseBundle.verifyExtraction(
        dir.path,
        {name: 10},
        expectedHashes: {name: sha256.convert(List.filled(10, 1)).toString()},
      );
      expect(problems.single, contains('is corrupted'));
      expect(problems.single, contains('SHA-256'));
    });

    test(
      'no manifest means nothing to check against, not everything wrong',
      () async {
        expect(
          await BughouseBundle.verifyExtraction(dir.path, const {}),
          isEmpty,
        );
      },
    );
  });
}
