import 'dart:io';

import 'package:chess_auto_prep/v2/storage/diagnostic_report.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  Directory? folder;
  setUp(() async => folder = await Directory.systemTemp.createTemp('report-'));
  tearDown(() async => folder?.delete(recursive: true));

  DiagnosticReport report({Future<String> Function()? application}) =>
      DiagnosticReport(
        folder!,
        application: application ?? () async => 'Version: 1.2.3+4',
        platform: 'test platform',
      );
  Future<void> write(String text) =>
      File(p.join(folder!.path, 'app.log')).writeAsString(text);

  test('version and platform are useful before any log exists', () async {
    final text = await report().read();
    expect(text, contains('Version: 1.2.3+4\ntest platform'));
    expect(text, contains('No app.log yet.'));
    expect(await folder!.list().isEmpty, isTrue);
  });

  test('only the last 160 lines are copied; source stays unchanged', () async {
    final original = List.generate(300, (i) => 'entry $i').join('\n');
    await write(original);
    final text = await report().read();
    expect(text, isNot(contains('entry 139\n')));
    expect(text, contains('entry 140\n'));
    expect(text, endsWith('entry 299'));
    expect(
      await File(p.join(folder!.path, 'app.log')).readAsString(),
      original,
    );
  });

  test('byte bound discards the leading partial line', () async {
    await write('${'é' * DiagnosticReport.maxBytes}\ncomplete last line');
    final text = await report().read();
    expect(text, endsWith('complete last line'));
    expect(text, isNot(contains('é')));
  });

  test('single oversized line is not copied in fragments', () async {
    await write('x' * (DiagnosticReport.maxBytes + 5));
    expect(await report().read(), endsWith('No complete recent log lines.'));
  });

  test('recognizable credentials omit the whole line', () async {
    await write(
      [
        'normal warning',
        'Authorization: Bearer sensitive',
        'access_token="sensitive with spaces"',
        'refresh-token = sensitive',
        'client_secret: sensitive',
        'code_verifier=sensitive',
        'password=sensitive',
        'https://localhost/callback?code=sensitive&state=xyz',
        'token=sensitive',
        'lip_sensitive',
        'last warning',
      ].join('\n'),
    );
    final text = await report().read();
    expect(text, isNot(contains('sensitive')));
    expect(text, contains('normal warning\n'));
    expect(text, endsWith('last warning'));
    expect('[Credential-bearing log line omitted]'.allMatches(text).length, 9);
  });

  test('missing package metadata still produces the log report', () async {
    await write('engine ended');
    final text = await report(
      application: () async => throw StateError('no metadata'),
    ).read();
    expect(text, contains('Version unavailable'));
    expect(text, endsWith('engine ended'));
  });

  test('invalid UTF-8 in a log does not prevent a report', () async {
    await File(p.join(folder!.path, 'app.log')).writeAsBytes([255, 10, 79, 75]);
    expect(await report().read(), endsWith('\nOK'));
  });
}
