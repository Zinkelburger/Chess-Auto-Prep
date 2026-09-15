/// The diagnostics behind a bughouse engine failure.
///
/// Assembled rather than logged piecemeal because the reader is usually not
/// the person who can read a log: the whole point is that someone can send
/// the block back without knowing what any of it means. Everything here is
/// static and, where it can be, pure — so the exact text a user will paste can
/// be asserted in a test on any platform, rather than only being seen when
/// something breaks.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../app_version.dart';
import 'bughouse_bundle.dart';
import 'windows_loader_check.dart';

abstract final class BughouseEngineReport {
  /// Reports the timeout and received output without inferring its cause.
  static String stalledMessage({
    required String what,
    required Duration timeout,
    required bool spoke,
    required List<String> stderr,
    required bool isWindows,
  }) {
    final buffer = StringBuffer(
      'Engine did not answer "$what" within ${timeout.inSeconds}s.',
    );
    if (!spoke) buffer.write(' No stdout received.');
    if (stderr.isNotEmpty) buffer.write('\n${stderr.take(8).join('\n')}');
    return buffer.toString();
  }

  /// Preserves the raw exit code and names known NTSTATUS/signal values.
  static String describeExit(int code, {bool? isWindows}) {
    final windows = isWindows ?? Platform.isWindows;
    // A process killed by a signal reaches Dart as the negated signal number,
    // and signals stop at 64; anything more negative is a Windows NTSTATUS
    // that arrived through a signed path, which is why the two readings can
    // share one function without a platform flag at every call site.
    if (!windows && code < 0 && -code <= 64) {
      final signal = switch (-code) {
        4 => 'SIGILL',
        6 => 'SIGABRT',
        9 => 'SIGKILL',
        11 => 'SIGSEGV',
        _ => 'signal ${-code}',
      };
      return 'Engine exited ($code; $signal)';
    }
    final status = code & 0xffffffff;
    final name = switch (status) {
      0xC0000135 => 'STATUS_DLL_NOT_FOUND',
      0xC0000139 => 'STATUS_ENTRYPOINT_NOT_FOUND',
      0xC0000142 => 'STATUS_DLL_INIT_FAILED',
      0xC000007B => 'STATUS_INVALID_IMAGE_FORMAT',
      0xC000001D => 'STATUS_ILLEGAL_INSTRUCTION',
      0xC0000005 => 'STATUS_ACCESS_VIOLATION',
      0xC0000409 => 'STATUS_STACK_BUFFER_OVERRUN',
      _ => null,
    };
    if (windows || name != null) {
      final hex = status.toRadixString(16).padLeft(8, '0').toUpperCase();
      return 'Engine exited ($code; 0x$hex${name == null ? '' : '; $name'})';
    }
    return 'Engine exited ($code)';
  }

  /// Collect each section independently, preserving the launch evidence if a
  /// file cannot be inspected. Inspect paths before repair removes any files.
  static Future<String> collect({
    required String headline,
    required String executablePath,
    required List<String> argv,
    required String workingDirectory,
    required Map<String, String> environment,
    required int? exitCode,
    required bool spoke,
    required List<String> stdout,
    required List<String> stderr,
    bool processStarted = true,
    Future<ContentVerification> Function()? verifyIntegrity,
  }) async {
    final errors = <String>[];
    List<String> directory = const [];
    List<DllResolution>? libraries;
    ContentVerification? integrity;
    try {
      directory = await describeDirectory(
        workingDirectory,
        BughouseBundle.expectedSizes,
      );
    } catch (e) {
      errors.add('File inspection failed: $e');
    }
    if (Platform.isWindows) {
      try {
        libraries = await WindowsLoaderCheck.resolveAll(
          engineDir: workingDirectory,
          environment: environment,
        );
      } catch (e) {
        errors.add('DLL inspection failed: $e');
      }
    }
    if (verifyIntegrity != null) {
      try {
        integrity = await verifyIntegrity();
      } catch (e) {
        errors.add('Integrity check failed: $e');
      }
    }
    final loaderVariable = Platform.isWindows
        ? 'PATH'
        : Platform.isMacOS
        ? 'DYLD_LIBRARY_PATH'
        : 'LD_LIBRARY_PATH';
    final loaderValue = environment.entries
        .where((e) => e.key.toUpperCase() == loaderVariable)
        .map((e) => e.value)
        .firstOrNull;
    return format(
      headline: headline,
      executablePath: executablePath,
      argv: argv,
      workingDirectory: workingDirectory,
      exitCode: exitCode,
      spoke: spoke,
      directory: directory,
      libraries: libraries,
      integrity: integrity,
      stdout: stdout,
      stderr: stderr,
      processStarted: processStarted,
      collectionErrors: errors,
      loaderPath: '$loaderVariable=${loaderValue ?? '(not set)'}',
    );
  }

  /// Minimal copyable evidence when installation failed before engine launch.
  static String unavailable(Object error) =>
      'BEGIN BUGHOUSE DIAGNOSTICS\n'
      'Chess Auto Prep $kAppVersion — bughouse engine diagnostics\n'
      'Error       : $error\n'
      'OS          : ${Platform.operatingSystemVersion}\n'
      'Dart        : ${Platform.version}\n'
      'App         : ${Platform.resolvedExecutable}\n'
      '${error is BughouseBundleBroken ? error.diagnostics.join('\n') : 'Engine diagnostics: unavailable for this failure'}\n'
      'END BUGHOUSE DIAGNOSTICS';

  /// The report itself, with every fact already gathered.
  static String format({
    required String headline,
    required String executablePath,
    ContentVerification? integrity,
    required List<String> argv,
    required String workingDirectory,
    required int? exitCode,
    required bool spoke,
    required List<String> directory,
    required List<DllResolution>? libraries,
    required List<String> stdout,
    required List<String> stderr,
    String? loaderPath,
    bool processStarted = true,
    List<String> collectionErrors = const [],
  }) {
    final out = StringBuffer()
      ..writeln('BEGIN BUGHOUSE DIAGNOSTICS')
      ..writeln('Chess Auto Prep $kAppVersion — bughouse engine diagnostics')
      ..writeln('Problem     : $headline')
      ..writeln(
        'Exit        : ${!processStarted
            ? 'not started'
            : exitCode == null
            ? 'not observed'
            : describeExit(exitCode)}',
      )
      ..writeln(
        'Spoke       : ${spoke ? 'stdout received' : 'no stdout received'}',
      )
      ..writeln('OS          : ${Platform.operatingSystemVersion}')
      ..writeln('Dart        : ${Platform.version}')
      ..writeln('App         : ${Platform.resolvedExecutable}')
      ..writeln('Engine      : $executablePath')
      ..writeln('Arguments   : ${jsonEncode(argv)}')
      ..writeln('Working dir : $workingDirectory');
    if (loaderPath != null) out.writeln('Library path: $loaderPath');
    if (BughouseBundle.installationDiagnostics.isNotEmpty) {
      out
        ..writeln('Dependency verification before launch')
        ..writeln(BughouseBundle.installationDiagnostics.join('\n'));
    }

    out
      ..writeln()
      ..writeln('Files beside the engine');
    out.writeln(
      directory.isEmpty ? '  (no files recorded)' : directory.join('\n'),
    );
    if (collectionErrors.isNotEmpty) {
      out.writeln(collectionErrors.join('\n'));
    }

    if (libraries != null) {
      out
        ..writeln()
        ..writeln(
          'DLL candidates (filesystem search; not a Windows loader trace)',
        )
        ..writeln(WindowsLoaderCheck.report(libraries));
      final problem = WindowsLoaderCheck.describe(libraries);
      if (problem != null) {
        out
          ..writeln()
          ..writeln('!! $problem');
      }
    }

    // Last, because it is the answer when everything above it looks right —
    // and on the machines this report was written for, everything above it
    // does look right.
    if (integrity != null && !integrity.isEmpty) {
      out
        ..writeln()
        ..writeln('File integrity and repair')
        ..writeln(integrity.lines.join('\n'));
      final repaired = integrity.repairedMessage;
      if (repaired != null) {
        out
          ..writeln()
          ..writeln('!! $repaired');
      }
    }

    if (integrity == null || integrity.isEmpty) {
      out.writeln('File integrity: no results available');
    }

    out
      ..writeln()
      ..writeln('Engine stderr')
      ..writeln(
        stderr.isEmpty ? '  (empty)' : stderr.map((l) => '  $l').join('\n'),
      )
      ..writeln()
      ..writeln('Engine stdout (first 24 lines)')
      ..writeln(
        stdout.isEmpty ? '  (empty)' : stdout.map((l) => '  $l').join('\n'),
      )
      ..writeln('END BUGHOUSE DIAGNOSTICS');
    return out.toString().trimRight();
  }

  /// One line per file in [directory]: its size, the size it should be, and on
  /// Windows the architecture of its image.
  ///
  /// A wrong size is what an interrupted extraction looks like, and Windows
  /// rejects a truncated DLL with the same status it uses for a 32-bit one —
  /// so having both readings side by side is what tells those two apart.
  @visibleForTesting
  static Future<List<String>> describeDirectory(
    String directory,
    Map<String, int> expected,
  ) async {
    final dir = Directory(directory);
    if (!await dir.exists()) return ['  (the directory does not exist)'];
    final lines = <String>[];
    await for (final entry in dir.list(followLinks: false)) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      final size = await entry.length();
      final want = expected[name];
      final buffer = StringBuffer(
        '  ${name.padRight(28)}${size.toString().padLeft(12)} bytes',
      );
      if (want != null) {
        buffer.write(size == want ? '  (size ok)' : '  SHOULD BE $want');
      }
      final extension = p.extension(name).toLowerCase();
      if (Platform.isWindows && (extension == '.dll' || extension == '.exe')) {
        buffer.write(
          '  [${WindowsLoaderCheck.describeMachine(await WindowsLoaderCheck.machineOfFile(entry))}]',
        );
      }
      lines.add(buffer.toString());
    }
    lines.sort();
    return lines;
  }
}
