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
    });
  }
}
