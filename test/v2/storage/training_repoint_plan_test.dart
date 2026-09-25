import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/training_records.dart';
import 'package:chess_auto_prep/v2/storage/training_rows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const names = [reviewsFile, streaksFile, historyFile, attemptsFile];
const reviewsHeader =
    'repertoire_id,line_id,line_name,difficulty,interval_days,due_utc,last_rating,last_reviewed_utc,pass_count,fail_count,excluded';
const historyHeader =
    'repertoire_id,line_id,timestamp_utc,rating,had_mistake,session_type';

void main() {
  late Directory documents;
  late TrainingRecords records;
  late DocumentRef from;
  late DocumentRef to;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('training-plan-');
    records = TrainingRecords(documents);
    from = DocumentRef(p.join(documents.path, 'chapters', 'before.pgn'));
    to = DocumentRef(p.join(documents.path, 'chapters', 'after.pgn'));
  });
  tearDown(() => documents.delete(recursive: true));

  File file(String name) => File(p.join(documents.path, name));
  String review(String path) =>
      '$path,line,Mainline,2.5,1,2026-09-01T00:00:00Z,good,2026-08-31T00:00:00Z,2,0,false';

  test(
    'plan keeps complete immutable read set including absent and empty files',
    () async {
      await file(streaksFile).writeAsString('');
      await file(historyFile).writeAsString(' \r\n');
      final plan = await records.plan(from, to);
      expect(plan.files.map((entry) => entry.name), names);
      expect(plan.files.map((entry) => entry.before), [
        null,
        '',
        ' \r\n',
        null,
      ]);
      expect(plan.files.map((entry) => entry.after), [null, '', ' \r\n', null]);
      expect(plan.files.every((entry) => !entry.changed), isTrue);
      expect(plan.rowsChanged, 0);
      expect(() => plan.files.clear(), throwsUnsupportedError);
      expect(
        await documents.list().map((entry) => p.basename(entry.path)).toList(),
        unorderedEquals([streaksFile, historyFile]),
      );
    },
  );

  test(
    'plan matches repoint bytes and count while leaving all files and backups untouched',
    () async {
      final before = {
        reviewsFile:
            '$reviewsHeader\r\n${review(from.path)}\r\n${review('/unrelated.pgn')}\r\n',
        streaksFile:
            'repertoire_id,line_id,move_index,correct_streak,learned\n${from.path},line,1,2,true\n',
        historyFile:
            '$historyHeader\n${from.path},line,2026-08-31T00:00:00Z,good,false,trainer\n',
        attemptsFile:
            '${jsonEncode({
              'repertoireId': from.path,
              'futureField': {
                'preserve': [1, 'two'],
              },
            })}\n'
            '{ "repertoireId": "/unrelated.pgn", "unknown": 17 }\n',
      };
      for (final entry in before.entries) {
        await file(entry.key).writeAsString(entry.value);
        await file(
          '${entry.key}.pre-csv-v2.bak',
        ).writeAsString('legacy backup');
      }
      final plan = await records.plan(from, to);
      expect(plan.rowsChanged, 4);
      expect(plan.files.map((entry) => entry.name), names);
      for (final entry in plan.files) {
        expect(entry.before, before[entry.name]);
        expect(entry.after, contains(to.path));
        expect(await file(entry.name).readAsString(), entry.before);
        expect(
          await file('${entry.name}.pre-csv-v2.bak').readAsString(),
          'legacy backup',
        );
      }
      expect(
        await Directory(
          p.join(documents.path, '.cap-reference-history'),
        ).exists(),
        isFalse,
      );
      final attempts = plan.files.last.after!.split('\n');
      expect(jsonDecode(attempts.first)['futureField'], {
        'preserve': [1, 'two'],
      });
      expect(
        attempts[1],
        '{ "repertoireId": "/unrelated.pgn", "unknown": 17 }',
      );
      final result = await records.repoint(from, to) as Repointed;
      expect(result.rowsChanged, plan.rowsChanged);
      for (final entry in plan.files) {
        expect(await file(entry.name).readAsString(), entry.after);
      }
    },
  );

  test(
    'same-path plan validates all participants without canonicalizing records',
    () async {
      final before =
          '$reviewsHeader\r\n"${from.path}",line,Mainline,2.5,1,2026-09-01T00:00:00Z,good,2026-08-31T00:00:00Z,2,0,false\r\n';
      await file(reviewsFile).writeAsString(before);
      final plan = await records.plan(from, from);
      expect(plan.rowsChanged, 0);
      expect(plan.files.first.before, before);
      expect(plan.files.first.after, before);
      await file(attemptsFile).writeAsString('malformed');
      await expectLater(records.plan(from, from), throwsA(isA<Malformed>()));
    },
  );

  test(
    'malformed last participant rejects full plan before writes or backups',
    () async {
      final before = '$reviewsHeader\n${review(from.path)}\n';
      await file(reviewsFile).writeAsString(before);
      await file(attemptsFile).writeAsString('{"repertoireId": 7}\n');
      await expectLater(
        records.plan(from, to),
        throwsA(
          isA<Malformed>()
              .having((error) => error.file, 'file', attemptsFile)
              .having((error) => error.line, 'line', 1),
        ),
      );
      expect(await file(reviewsFile).readAsString(), before);
      expect(
        await Directory(
          p.join(documents.path, '.cap-reference-history'),
        ).exists(),
        isFalse,
      );
    },
  );

  for (final kind in [
    'directory',
    'symlink',
    'dangling symlink',
    'invalid UTF-8',
  ]) {
    test(
      'plan refuses $kind participant instead of treating it as absent',
      () async {
        final target = file(attemptsFile);
        switch (kind) {
          case 'directory':
            await Directory(target.path).create();
          case 'symlink':
            final destination = await file('actual').writeAsString('');
            await Link(target.path).create(destination.path);
          case 'dangling symlink':
            await Link(target.path).create(file('missing').path);
          case 'invalid UTF-8':
            await target.writeAsBytes([0xc3]);
        }
        await expectLater(records.plan(from, to), throwsA(isA<IoFailure>()));
      },
      skip: !Platform.isLinux,
    );
  }

  test(
    'captured snapshots reconstruct the exact native plan without disk reads',
    () async {
      final before = <String, String?>{
        reviewsFile: '\ufeff$reviewsHeader\r\n${review(from.path)}\r\n',
        streaksFile: '',
        historyFile: null,
        attemptsFile: '{ "repertoireId": "${from.path}", "future": [1,2] }\n',
      };
      for (final entry in before.entries) {
        if (entry.value != null)
          await file(entry.key).writeAsString(entry.value!);
      }
      final native = await records.plan(from, to);
      for (final entry in await documents.list().toList()) {
        await entry.delete();
      }
      final captured = TrainingRepointPlan.fromSnapshots(
        from: from,
        to: to,
        before: before,
      );
      before[reviewsFile] = 'changed after acceptance';
      expect(captured.rowsChanged, native.rowsChanged);
      expect(captured.files.map((entry) => entry.name), names);
      expect(
        captured.files.map((entry) => entry.before),
        native.files.map((entry) => entry.before),
      );
      expect(
        captured.files.map((entry) => entry.after),
        native.files.map((entry) => entry.after),
      );
      expect(await documents.list().toList(), isEmpty);
    },
  );

  test('captured snapshots require exactly the fixed four participants', () {
    final before = <String, String?>{for (final name in names) name: null};
    for (final invalid in [
      {...before}..remove(attemptsFile),
      {...before, 'unexpected.csv': null},
    ]) {
      expect(
        () => TrainingRepointPlan.fromSnapshots(
          from: from,
          to: to,
          before: invalid,
        ),
        throwsFormatException,
      );
    }
  });

  test('captured snapshots validate malformed unchanged participants', () {
    expect(
      () => TrainingRepointPlan.fromSnapshots(
        from: from,
        to: from,
        before: {
          for (final name in names)
            name: name == attemptsFile ? 'malformed' : null,
        },
      ),
      throwsA(
        isA<Malformed>().having((error) => error.file, 'file', attemptsFile),
      ),
    );
  });

  test(
    'canonical and configured alias records both retain their spelling',
    () async {
      final alternateFrom = DocumentRef(
        p.join(documents.path, 'alias', 'before.pgn'),
      );
      final alternateTo = DocumentRef(
        p.join(documents.path, 'alias', 'after.pgn'),
      );
      final before = <String, String?>{
        reviewsFile:
            '$reviewsHeader\n${review(from.path)}\n${review(alternateFrom.path)}\n',
        streaksFile: null,
        historyFile: '',
        attemptsFile:
            '${jsonEncode({'repertoireId': from.path})}\n'
            '${jsonEncode({'repertoireId': alternateFrom.path, 'future': true})}\n',
      };
      for (final entry in before.entries) {
        if (entry.value != null)
          await file(entry.key).writeAsString(entry.value!);
      }
      final captured = TrainingRepointPlan.fromSnapshots(
        from: from,
        to: to,
        before: before,
        alternateFrom: alternateFrom,
        alternateTo: alternateTo,
      );
      final native = await records.plan(
        from,
        to,
        alternateFrom: alternateFrom,
        alternateTo: alternateTo,
      );
      expect(captured.rowsChanged, 4);
      expect(native.rowsChanged, 4);
      expect(
        captured.files.map((entry) => entry.before),
        names.map((name) => before[name]),
      );
      expect(
        captured.files.map((entry) => entry.after),
        native.files.map((entry) => entry.after),
      );
      expect(
        captured.files.first.after,
        '$reviewsHeader\n${review(to.path)}\n${review(alternateTo.path)}\n',
      );
      final attempts = captured.files.last.after!.split('\n');
      expect(jsonDecode(attempts[0]), {'repertoireId': to.path});
      expect(jsonDecode(attempts[1]), {
        'repertoireId': alternateTo.path,
        'future': true,
      });
    },
  );

  test('a partial alternate path mapping is refused', () {
    expect(
      () => TrainingRepointPlan.fromSnapshots(
        from: from,
        to: to,
        before: {for (final name in names) name: null},
        alternateFrom: from,
      ),
      throwsArgumentError,
    );
  });

  test('UTF-8 BOM remains part of the exact before and after texts', () async {
    final body = '$reviewsHeader\n${review(from.path)}\n';
    final bytes = [0xef, 0xbb, 0xbf, ...utf8.encode(body)];
    await file(reviewsFile).writeAsBytes(bytes);
    final plan = await records.plan(from, to);
    expect(utf8.encode(plan.files.first.before!), bytes);
    expect(plan.files.first.after, startsWith('\ufeff$reviewsHeader'));
    expect(plan.rowsChanged, 1);
    expect(await file(reviewsFile).readAsBytes(), bytes);
  });
}
