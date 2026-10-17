import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/storage/recovery_gate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory profile;
  late Directory documents;
  late Directory support;
  late Directory alias;
  late File harness;
  late Directory harnessFolder;

  setUp(() async {
    profile = await Directory.systemTemp.createTemp('recovery-domain-');
    documents = await Directory(p.join(profile.path, 'Documents')).create();
    support = await Directory(p.join(profile.path, 'Support')).create();
    await Directory(p.join(documents.path, 'repertoires')).create();
    await File(
      p.join(documents.path, 'repertoire_reviews.csv'),
    ).writeAsString('unchanged');
    alias = Directory(p.join(profile.path, 'alias'));
    await Link(alias.path).create(documents.path);
    // Keep the executable inside the package so dart run resolves the same
    // generated native assets as the app; user data remains in the temp profile.
    harnessFolder = await Directory(
      p.join(Directory.current.path, '.dart_tool'),
    ).createTemp('recovery-domain-');
    harness = File(p.join(harnessFolder.path, 'hold_domain.dart'));
    await harness.writeAsString(_harness);
  });
  tearDown(() async {
    await profile.delete(recursive: true);
    await harnessFolder.delete(recursive: true);
  });

  // The child is another copy of the app: a separate process that holds the
  // domain through its own gate.
  const folder = 'relocation-writes';
  test(
    'another copy\'s domain excludes the app through a canonical alias',
    () async {
      final child = await _hold(harness, alias, support, false);
      addTearDown(child.close);
      var entered = false;
      final reading = RecoveryGate(documents: documents, support: support).run(
        () async {
          entered = true;
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(
        entered,
        isFalse,
        reason: 'the actual child process still owns the domain',
      );
      child.process.stdin.writeln('release');
      expect(
        await child.process.exitCode.timeout(const Duration(seconds: 10)),
        0,
      );
      await reading.timeout(const Duration(seconds: 10));
      expect(entered, isTrue);
    },
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'killing another copy releases the domain and the app keeps working',
    () async {
      final child = await _hold(harness, documents, support, true);
      addTearDown(child.close);
      final metadata = File(p.join(support.path, folder, '1-a.json'));
      expect(await metadata.readAsString(), 'interrupted-json');
      expect(child.process.kill(ProcessSignal.sigkill), isTrue);
      await child.process.exitCode.timeout(const Duration(seconds: 10));
      // A damaged leftover is logged or set aside, never a reason to
      // refuse access.
      final reading = RecoveryGate(
        documents: alias,
        support: support,
      ).run(() async => 'read');
      expect(await reading.timeout(const Duration(seconds: 10)), 'read');
      expect(await _quarantined(support), contains('interrupted-json'));
      expect(
        await File(
          p.join(documents.path, 'repertoire_reviews.csv'),
        ).readAsString(),
        'unchanged',
      );
    },
    skip: !Platform.isLinux,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

/// The contents of every file set aside under Support/recovery-quarantine.
Future<List<String>> _quarantined(Directory support) async {
  final folder = Directory(p.join(support.path, 'recovery-quarantine'));
  if (!await folder.exists()) return const [];
  return [
    await for (final entry in folder.list(recursive: true))
      if (entry is File) await entry.readAsString(),
  ];
}

Future<_Child> _hold(
  File harness,
  Directory documents,
  Directory support,
  bool interrupted,
) async {
  final process = await Process.start('dart', [
    'run',
    '--packages=${p.join(Directory.current.path, '.dart_tool', 'package_config.json')}',
    harness.path,
    documents.path,
    support.path,
    '$interrupted',
  ], workingDirectory: Directory.current.path);
  final ready = Completer<void>();
  final diagnostics = StringBuffer();
  final output = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        if (line == 'domain held' && !ready.isCompleted) ready.complete();
        diagnostics.writeln(line);
      });
  final errors = process.stderr
      .transform(utf8.decoder)
      .listen(diagnostics.write);
  unawaited(
    process.exitCode.then((code) {
      if (!ready.isCompleted) {
        ready.completeError(StateError('Child exited $code: $diagnostics'));
      }
    }),
  );
  final child = _Child(process, output, errors);
  try {
    await ready.future.timeout(const Duration(seconds: 40));
    return child;
  } on Object {
    await child.close();
    rethrow;
  }
}

final class _Child {
  _Child(this.process, this.output, this.errors);
  final Process process;
  final StreamSubscription<String> output;
  final StreamSubscription<String> errors;

  Future<void> close() async {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    await output.cancel();
    await errors.cancel();
  }
}

// Real separate Dart VM process holding the domain through the app's gate.
// The malformed retained record models a crash during metadata publication:
// it may not be taken for no pending operation.
const _harness = r'''
import 'dart:convert';
import 'dart:io';
import 'package:chess_auto_prep/storage/recovery_gate.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final documents = Directory(args[0]);
  final support = Directory(args[1]);
  Future<void> hold() async {
    if (args[2] == 'true') {
      final folder = Directory(p.join(support.path, 'relocation-writes'));
      await folder.create();
      await File(p.join(folder.path, '1-a.json')).writeAsString('interrupted-json', flush: true);
    }
    stdout.writeln('domain held');
    await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
  }
  final gate = RecoveryGate(documents: documents, support: support);
  await gate.run(hold);
}
''';
