import 'dart:convert';

import 'package:chess_auto_prep/services/eval/cdb_snapshot_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

/// Trimmed copies of what the mirror's tree API actually returns.
const _treeBody = '''
[
  {"type":"file","oid":"bc13","size":4305257543,
   "lfs":{"oid":"2593d4ad","size":4305257543,"pointerSize":135},
   "path":"chess-20260702/data/152797.sst"},
  {"type":"file","oid":"f8f8","size":4304675176,
   "lfs":{"oid":"d78970a0","size":4304675176,"pointerSize":135},
   "path":"chess-20260702/data/152796.sst"},
  {"type":"file","oid":"a0e5","size":16,"path":"chess-20260702/data/CURRENT"},
  {"type":"directory","oid":"dead","size":0,"path":"chess-20260702/extra"}
]
''';

const _rootBody = '''
[
  {"type":"directory","oid":"1","size":0,"path":"chess-20240814"},
  {"type":"directory","oid":"2","size":0,"path":"chess-20260702"},
  {"type":"directory","oid":"3","size":0,"path":"chess-20251115"},
  {"type":"directory","oid":"4","size":0,"path":"xiangqi-20260702"},
  {"type":"file","oid":"5","size":1551,"path":"README.md"}
]
''';

void main() {
  group('parseHfTreeFiles', () {
    test('keeps files with their sizes and LFS digests', () {
      final files = parseHfTreeFiles(_treeBody);
      expect(files.map((f) => f.name), ['152796.sst', '152797.sst', 'CURRENT']);
      expect(files.first.bytes, 4304675176);
      expect(files.first.sha256, 'd78970a0');
    });

    test('a non-LFS file carries no digest', () {
      final current = parseHfTreeFiles(
        _treeBody,
      ).firstWhere((f) => f.name == 'CURRENT');
      expect(current.sha256, isNull);
      expect(current.bytes, 16);
    });

    test('directories are skipped', () {
      expect(
        parseHfTreeFiles(_treeBody).where((f) => f.name == 'extra'),
        isEmpty,
      );
    });

    test('a malformed body yields nothing rather than throwing', () {
      expect(parseHfTreeFiles('{"error":"nope"}'), isEmpty);
      expect(parseHfTreeFiles('[{"type":"file","path":"x"}]'), isEmpty);
    });
  });

  group('parseHfSnapshotIds', () {
    test('chess snapshots only, newest first', () {
      expect(parseHfSnapshotIds(_rootBody), [
        'chess-20260702',
        'chess-20251115',
        'chess-20240814',
      ]);
    });
  });

  group('parseSnapshotDate', () {
    test('reads the date out of the id', () {
      expect(parseSnapshotDate('chess-20260702'), DateTime(2026, 7, 2));
    });

    test('rejects anything that is not a chess snapshot', () {
      expect(parseSnapshotDate('xiangqi-20260702'), isNull);
      expect(parseSnapshotDate('chess-2026'), isNull);
      expect(parseSnapshotDate('chess-20261302'), isNull);
    });
  });

  group('parseHfNextLink', () {
    test('extracts the next page', () {
      expect(
        parseHfNextLink('<https://hf.co/api/x?cursor=abc>; rel="next"'),
        Uri.parse('https://hf.co/api/x?cursor=abc'),
      );
    });

    test('null when the last page is reached', () {
      expect(parseHfNextLink(null), isNull);
      expect(parseHfNextLink('<https://hf.co/first>; rel="first"'), isNull);
    });
  });

  group('CdbSnapshot', () {
    test('totalBytes sums the manifest', () {
      final snap = CdbSnapshot(
        id: 'chess-20260702',
        files: parseHfTreeFiles(_treeBody),
      );
      expect(snap.totalBytes, 4305257543 + 4304675176 + 16);
      expect(snap.date, DateTime(2026, 7, 2));
    });
  });

  group('chessDbFileUrl', () {
    test('resolves against the dataset mirror', () {
      expect(
        chessDbFileUrl('chess-20260702/data/152796.sst').toString(),
        'https://huggingface.co/datasets/$kChessDbHfRepo/resolve/main/'
        'chess-20260702/data/152796.sst',
      );
    });
  });

  test('json fixtures are valid', () {
    expect(jsonDecode(_treeBody), isA<List<dynamic>>());
    expect(jsonDecode(_rootBody), isA<List<dynamic>>());
  });
}
