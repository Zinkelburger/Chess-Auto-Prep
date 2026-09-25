import 'dart:convert';

import 'package:chess_auto_prep/v2/storage/book_references.dart';
import 'package:chess_auto_prep/v2/storage/reference_change.dart';
import 'package:flutter_test/flutter_test.dart';

const root = '/Documents/repertoires';
const chapter = '$root/Course/Main.pgn';
const change = SectionRename(path: chapter, from: 'A', to: 'B');

Map<String, Object?> fixture() => decoded(
  jsonEncode({
    'version': 1,
    'active': 'book',
    'future': {
      'deep': [true, null, 17],
    },
    'books': [
      {
        'id': 'book',
        'name': 'Event',
        'future': [3, 2, 1],
        'repertoires': ['Course'],
        'chapters': [
          {
            'path': 'Course/Main.pgn',
            'section': 'A',
            'future': {'notes': 'keep'},
          },
          {'path': 'Course/Main.pgn', 'section': null},
          {'path': 'Course/Main.pgn', 'section': 'Other'},
          {'path': 'Else/Main.pgn', 'section': 'A'},
        ],
      },
      {'id': 'other', 'name': 'Other', 'repertoires': [], 'chapters': []},
    ],
  }),
);

List<Object?> books(Map<String, Object?> value) =>
    value['books'] as List<Object?>;
Map<String, Object?> firstBook(Map<String, Object?> value) =>
    books(value).first as Map<String, Object?>;
List<Object?> selectors(Map<String, Object?> value) =>
    firstBook(value)['chapters'] as List<Object?>;
Map<String, Object?> selector(Map<String, Object?> value, [int at = 0]) =>
    selectors(value)[at] as Map<String, Object?>;

String? rename(String? value, [List<SectionRename> changes = const [change]]) =>
    renameBookReferences(value, repertoireRoot: root, changes: changes);
Map<String, Object?> decoded(String text) =>
    jsonDecode(text) as Map<String, Object?>;

void main() {
  String? relocate(
    String? text,
    String from,
    String to, {
    bool directory = false,
  }) => relocateBookReferences(
    text,
    repertoireRoot: root,
    from: from,
    to: to,
    directory: directory,
  );

  group('path relocation', () {
    test('absent books stay absent', () {
      expect(relocate(null, chapter, '$root/New.pgn'), isNull);
    });

    test(
      'file move preserves sections, duplicates, order and unknown metadata',
      () {
        final before = fixture();
        selectors(
          before,
        ).add({'path': 'Course/Main.pgn', 'section': 'A', 'unknown': 42});
        selectors(
          before,
        ).add({'path': 'Course/Main.pgn/Child.pgn', 'section': null});
        firstBook(before)['repertoires'] = [
          'Course',
          'Course/Main.pgn',
          'Course/Main.pgn/child',
        ];
        books(before).add({
          'id': 'book',
          'name': 'Duplicate',
          'chapters': [
            {
              'path': 'Course/Main.pgn',
              'opaque': ['x', true],
            },
          ],
        });
        final expected = decoded(jsonEncode(before));
        for (final book in books(expected).cast<Map<String, Object?>>()) {
          for (final selector
              in (book['chapters'] as List).cast<Map<String, Object?>>()) {
            if (selector['path'] == 'Course/Main.pgn')
              selector['path'] = 'Other/Moved.pgn';
          }
        }
        (firstBook(expected)['repertoires'] as List)[1] = 'Other/Moved.pgn';
        expect(
          decoded(
            relocate(jsonEncode(before), chapter, '$root/Other/Moved.pgn')!,
          ),
          expected,
        );
      },
    );

    test(
      'folder move maps descendants and exact selectors but respects boundaries',
      () {
        final before = fixture();
        firstBook(before)['repertoires'] = [
          'Course',
          'Course/Nested',
          'Course2',
          'Course/Nested',
        ];
        selectors(before).addAll([
          {'path': 'Course/Nested/Deep.pgn', 'section': 'Keep'},
          {'path': 'Course2/Main.pgn'},
          {'path': 'Course'},
        ]);
        final expected = decoded(jsonEncode(before));
        firstBook(expected)['repertoires'] = [
          'Archive/New',
          'Archive/New/Nested',
          'Course2',
          'Archive/New/Nested',
        ];
        for (final item in selectors(expected).cast<Map<String, Object?>>()) {
          final path = item['path'] as String;
          if (path == 'Course' || path.startsWith('Course/'))
            item['path'] = 'Archive/New${path.substring('Course'.length)}';
        }
        expect(
          decoded(
            relocate(
              jsonEncode(before),
              '$root/Course',
              '$root/Archive/New',
              directory: true,
            )!,
          ),
          expected,
        );
      },
    );

    for (final directory in [false, true]) {
      test(
        '${directory ? 'folder' : 'file'} quarantine and restore retain selectors away from a reused old path',
        () {
          final before = fixture();
          final from = directory ? '$root/Course' : chapter;
          final to = directory
              ? '$root/.cap-pgn-history/deleted-1/Course'
              : '$root/Course/.cap-pgn-history/deleted-1.pgn';
          final moved = relocate(
            jsonEncode(before),
            from,
            to,
            directory: directory,
          )!;
          final paths = selectors(
            decoded(moved),
          ).cast<Map<String, Object?>>().map((s) => s['path']).toList();
          expect(
            paths.take(3),
            everyElement(
              directory
                  ? '.cap-pgn-history/deleted-1/Course/Main.pgn'
                  : 'Course/.cap-pgn-history/deleted-1.pgn',
            ),
          );
          expect(paths, isNot(contains('Course/Main.pgn')));
          expect(
            decoded(relocate(moved, to, from, directory: directory)!),
            before,
          );
        },
      );
    }

    test(
      'unaffected JSON remains byte exact, including absent optional selectors',
      () {
        final original =
            '${const JsonEncoder.withIndent('    ').convert(fixture())}\n';
        expect(relocate(original, chapter, chapter), original);
        expect(
          relocate(
            original,
            '$root/Elsewhere',
            '$root/Elsewhere2',
            directory: true,
          ),
          original,
        );
        expect(
          relocate(original, '/Outside/A', '/Outside/B', directory: true),
          original,
        );
        const optional =
            '{ "version":1, "active":"missing", "books":[{"id":"b","name":"N","extra":7}]}';
        expect(relocate(optional, chapter, '$root/New.pgn'), optional);
      },
    );

    for (final paths in [
      (chapter, '/Outside/Main.pgn'),
      ('/Outside/Main.pgn', chapter),
      (chapter, '/Documents/repertoires-extra/Main.pgn'),
      ('$root', '$root/Renamed'),
      ('Course/Main.pgn', '$root/Moved.pgn'),
      (chapter, '$root/../Moved.pgn'),
      (chapter, '$root/Bad\\Name.pgn'),
      ('$root/Bad\\Name.pgn', chapter),
    ]) {
      test('unrepresentable or noncanonical mapping is refused: $paths', () {
        expect(
          () => relocate(jsonEncode(fixture()), paths.$1, paths.$2),
          throwsFormatException,
        );
      });
    }
  });

  test('missing books remains missing', () => expect(rename(null), isNull));

  test(
    'only the exact partial selector changes and unknown fields survive',
    () {
      final before = fixture();
      final expected = fixture();
      selector(expected)['section'] = 'B';
      expect(decoded(rename(jsonEncode(before))!), expected);
    },
  );

  test('matching duplicate selectors keep distinct unknown metadata', () {
    final before = fixture();
    selectors(
      before,
    ).add({'path': 'Course/Main.pgn', 'section': 'A', 'future': 42});
    final after = decoded(rename(jsonEncode(before))!);
    expect(selectors(after), hasLength(5));
    expect(selector(after)['section'], 'B');
    expect(selector(after, 4), {
      'path': 'Course/Main.pgn',
      'section': 'B',
      'future': 42,
    });
  });

  test('all books are rewritten without dropping duplicate ids', () {
    final before = fixture();
    books(before).add({
      'id': 'book',
      'name': 'Duplicate',
      'chapters': [
        {'path': 'Course/Main.pgn', 'section': 'A'},
      ],
    });
    final after = decoded(rename(jsonEncode(before))!);
    final last = books(after).last as Map<String, Object?>;
    expect((last['chapters'] as List).single, {
      'path': 'Course/Main.pgn',
      'section': 'B',
    });
    expect(books(after), hasLength(3));
  });

  test('whole-file and folder selectors are unaffected', () {
    final before = fixture();
    selector(before)['section'] = null;
    final text = '${const JsonEncoder.withIndent('    ').convert(before)}\n';
    expect(rename(text), text);
  });

  test('accepted renames apply in order, including repeats', () {
    final text = jsonEncode(fixture());
    final after = decoded(
      rename(text, [
        change,
        change,
        const SectionRename(path: chapter, from: 'B', to: 'C'),
      ])!,
    );
    expect(selector(after)['section'], 'C');
    expect(rename(rename(text)!), rename(text));
  });

  test('a roundtrip returns the exact original bytes', () {
    final text = '${const JsonEncoder.withIndent('    ').convert(fixture())}\n';
    expect(
      rename(text, [
        change,
        const SectionRename(path: chapter, from: 'B', to: 'A'),
      ]),
      text,
    );
  });

  test('no changes or unrelated paths preserve the exact raw text', () {
    final text = '${const JsonEncoder.withIndent('    ').convert(fixture())}\n';
    expect(rename(text, []), text);
    expect(
      rename(text, [
        const SectionRename(path: '$root/Another.pgn', from: 'A', to: 'B'),
      ]),
      text,
    );
    expect(
      rename(text, [
        const SectionRename(
          path: '/Outside/Course/Main.pgn',
          from: 'A',
          to: 'B',
        ),
      ]),
      text,
    );
    expect(
      rename(text, [
        const SectionRename(
          path: '/Documents/repertoires-extra/Course/Main.pgn',
          from: 'A',
          to: 'B',
        ),
      ]),
      text,
    );
  });

  test('absent optional selectors and stale active id are preserved', () {
    const text =
        '{ "version":1, "active":"missing", "books":[{"id":"b","name":"N","unknown":7}]}';
    expect(rename(text), text);
  });

  for (final text in [
    '',
    '{',
    'null',
    '[]',
    '{}',
    '{"books":[]}',
    '{"version":2,"books":[]}',
    '{"version":1,"books":{}}',
    '{"version":1,"books":[null]}',
    '{"version":1,"books":[],"active":4}',
  ]) {
    test('invalid book envelope is refused: $text', () {
      expect(() => rename(text), throwsFormatException);
      expect(() => rename(text, []), throwsFormatException);
      expect(
        () => relocate(text, chapter, '$root/Moved.pgn'),
        throwsFormatException,
      );
      expect(
        () => relocate(text, '/Outside/A', '/Outside/B'),
        throwsFormatException,
      );
    });
  }

  for (final field in [
    'id',
    'name',
    'repertoires',
    'folder',
    'chapters',
    'chapter',
    'path',
    'absolute',
    'escape',
    'backslash',
    'section',
  ]) {
    test('invalid $field is refused even when another selector matches', () {
      final before = fixture();
      final book = firstBook(before);
      switch (field) {
        case 'id':
          book.remove('id');
        case 'name':
          book['name'] = 1;
        case 'repertoires':
          book['repertoires'] = null;
        case 'folder':
          book['repertoires'] = ['Course', 1];
        case 'chapters':
          book['chapters'] = 'not a list';
        case 'chapter':
          selectors(before).add(7);
        case 'path':
          selectors(before).add({'section': 'A'});
        case 'absolute':
          selectors(before).add({'path': '/Course/Main.pgn', 'section': 'A'});
        case 'escape':
          selectors(before).add({'path': '../Course/Main.pgn', 'section': 'A'});
        case 'backslash':
          selectors(before).add({'path': r'Course\Main.pgn', 'section': 'A'});
        case 'section':
          selectors(before).add({'path': 'Course/Main.pgn', 'section': 1});
      }
      expect(() => rename(jsonEncode(before)), throwsFormatException);
      expect(
        () => relocate(jsonEncode(before), chapter, '$root/Moved.pgn'),
        throwsFormatException,
      );
      expect(
        () => relocate(jsonEncode(before), '/Outside/A', '/Outside/B'),
        throwsFormatException,
      );
    });
  }
}
