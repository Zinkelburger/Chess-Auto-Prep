import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chess_auto_prep/v2/chess/training/schedule.dart';
import 'package:chess_auto_prep/v2/storage/csv_records.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/training_intent.dart';
import 'package:chess_auto_prep/v2/storage/training_payload.dart';
import 'package:chess_auto_prep/v2/storage/training_rows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final _documents = p.join(
  Directory.systemTemp.path,
  'training-intent-documents',
);
final _support = p.join(Directory.systemTemp.path, 'training-intent-support');
final _source = p.join(_documents, 'Course.pgn');
final _key = (source: _source, id: 'line');

void main() {
  final row = encodeCsvRecord(
    encodeReview(Review(key: _key, lineName: 'Line')),
  );
  String payload() => jsonEncode([
    'write',
    [
      [null, row],
    ],
    [],
    [],
  ]);

  test(
    'only a full deterministic four-file plan can authorize publication',
    () {
      final note = _committing(payload());
      expect(_decode(note.toJson()).state, 'committing');
      for (final name in trainingFileNames) {
        final changed = _committing(payload());
        final file = changed.files!.singleWhere((file) => file['name'] == name);
        file['after'] = base64Encode(utf8.encode('unrelated replacement'));
        changed.planDigest = changed.digestPlan(changed.files!);
        expect(
          () => _decode(changed.toJson()),
          throwsFormatException,
          reason: name,
        );
      }
    },
  );

  for (final invalid in <String, Object Function()>{
    'duplicate row identity': () => [
      'write',
      [
        [null, row],
        [null, row],
      ],
      [],
      [],
    ],
    'row changes identity': () => [
      'write',
      [
        [row, row.replaceFirst(',line,', ',different,')],
      ],
      [],
      [],
    ],
    'unknown review flag': () => [
      'write',
      [
        [null, row.replaceFirst('false', 'unknown')],
      ],
      [],
      [],
    ],
    'noncanonical review width': () => [
      'write',
      [
        [null, row.split(',').take(8).join(',')],
      ],
      [],
      [],
    ],
    'unknown attempt phase': () => [
      'attempt',
      jsonEncode(_attempt(phase: 'invented')),
    ],
    'unknown attempt fields': () => [
      'attempt',
      jsonEncode({..._attempt(), 'extra': true}),
    ],
    'embedded null text': () => [
      'attempt',
      jsonEncode({..._attempt(), 'playedSan': 'e4\u0000'}),
    ],
    'history without source proof': () => [
      'write',
      [],
      [],
      [
        [
          p.join(_documents, 'Other.pgn'),
          'line',
          '2026-09-25T00:00:00Z',
          'good',
          '0',
          'trainer',
        ],
      ],
    ],
  }.entries) {
    test('recomputed digest does not admit ${invalid.key}', () {
      final note = _queued(jsonEncode(invalid.value()));
      expect(() => _decode(note.toJson()), throwsFormatException);
    });
  }

  test('compact completion admits only the same ordered command and plan', () {
    final queued = _queued(payload());
    final committing = _committing(payload());
    final complete = {
      ...committing.toJson(),
      'state': 'complete',
      'payload': null,
      'files': null,
    };
    _decode(complete);
    expect(trainingPredecessor(queued.toJson(), complete), isTrue);
    expect(trainingPredecessor(committing.toJson(), complete), isTrue);
    expect(trainingPredecessor(complete, committing.toJson()), isFalse);
    expect(
      trainingPredecessor(committing.toJson(), {
        ...complete,
        'planDigest': 'b' * 64,
      }),
      isFalse,
    );
    expect(
      trainingPredecessor(queued.toJson(), {
        ...complete,
        'dependency': 'another',
      }),
      isFalse,
    );
    expect(
      trainingPredecessor(queued.toJson(), {...complete, 'sequence': 2}),
      isFalse,
    );
  });

  test('changing a review preserves BOM and unrelated quoted CRLF record', () {
    final other = encodeCsvRecord(
      encodeReview(
        Review(
          key: (source: _source, id: 'other'),
          lineName: 'Other, untouched',
        ),
      ),
    );
    final original = Uint8List.fromList(
      utf8.encode('\ufeff$reviewsHeader\r\n$other\r\n'),
    );
    final planned = TrainingPayload.decode(payload()).plan({
      for (final name in trainingFileNames)
        name: name == reviewsFile ? original : null,
    });
    expect(planned[reviewsFile]!.take(3), [0xef, 0xbb, 0xbf]);
    expect(utf8.decode(planned[reviewsFile]!), contains('$other\r\n'));
    expect(planned[historyFile], isNull);
    expect(planned[attemptsFile], isNull);
  });

  test('attempt materialization preserves a torn UTF8 tail byte for byte', () {
    final original = Uint8List.fromList([
      ...utf8.encode('{"legacy":true}\n'),
      0xe2,
      0x82,
    ]);
    final text = jsonEncode(_attempt());
    final planned = TrainingPayload.decode(jsonEncode(['attempt', text])).plan({
      for (final name in trainingFileNames)
        name: name == attemptsFile ? original : null,
    });
    expect(planned[attemptsFile], [...original, ...utf8.encode('\n$text\n')]);
  });
}

TrainingIntent _queued(String payload) => TrainingIntent(
  trainingCore(
    id: 'rating-1',
    sequence: 1,
    previous: null,
    dependency: null,
    documents: _documents,
    support: _support,
    trainingRoot: _documents,
    sources: {_source: Revision('a' * 64, nativeIdentity: 'native-original')},
    payload: payload,
  ),
  'queued',
  payload,
  null,
  null,
);

TrainingIntent _committing(String payload) {
  final note = _queued(payload);
  final before = <String, Uint8List?>{
    for (final name in trainingFileNames) name: null,
  };
  final after = TrainingPayload.decode(payload).plan(before);
  note.files = [
    for (final name in trainingFileNames)
      {
        'name': name,
        'before': null,
        'after': after[name] == null ? null : base64Encode(after[name]!),
      },
  ];
  note.state = 'committing';
  note.planDigest = note.digestPlan(note.files!);
  return note;
}

TrainingIntent _decode(Map<String, Object?> json) => TrainingIntent.decode(
  json,
  'rating-1',
  documents: _documents,
  support: _support,
);

Map<String, Object?> _attempt({String phase = 'drilling'}) => {
  'repertoireId': _source,
  'lineId': 'line',
  'moveIndex': 0,
  'fen': 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
  'playedSan': 'd4',
  'expectedSan': 'e4',
  'correct': false,
  'phase': phase,
  'timestampUtc': '2026-09-25T00:00:00.000Z',
};
