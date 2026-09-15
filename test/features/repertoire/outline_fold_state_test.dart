import 'package:chess_auto_prep/features/repertoire/controllers/outline_fold_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final root = p.join('/reps', 'French');
  final sidelines = p.join(root, 'Sidelines');
  final rare = p.join(sidelines, 'Rare');
  final exchange = p.join(sidelines, 'Exchange.pgn');
  final advance = p.join(root, 'Advance.pgn');

  late OutlineFoldState fold;
  setUp(() => fold = OutlineFoldState(rootPath: () => root));

  test('the root is always expanded and cannot be toggled', () {
    expect(fold.isExpanded(root), isTrue);
    expect(fold.toggleFolder(root), isFalse);
    expect(fold.isExpanded(root), isTrue);
    expect(fold.isExpanded(sidelines), isFalse);
  });

  test('folders and chapters toggle', () {
    expect(fold.toggleFolder(sidelines), isTrue);
    expect(fold.isExpanded(sidelines), isTrue);
    fold.toggleFolder(sidelines);
    expect(fold.isExpanded(sidelines), isFalse);

    fold.toggleChapter(advance);
    expect(fold.isChapterOpen(advance), isTrue);
    expect(fold.setChapterOpen(advance, true), isFalse, reason: 'no change');
    expect(fold.setChapterOpen(advance, false), isTrue);
    expect(fold.isChapterOpen(advance), isFalse);
  });

  test('reveal expands every folder above the chapter and unfolds it', () {
    final deep = p.join(rare, 'Deep.pgn');
    fold.reveal(deep);
    expect(fold.isExpanded(sidelines), isTrue);
    expect(fold.isExpanded(rare), isTrue);
    expect(fold.isChapterOpen(deep), isTrue);
  });

  test('a renamed chapter stays unfolded under its new path', () {
    fold.openChapter(exchange);
    final renamed = p.join(sidelines, 'Exchange variation.pgn');
    fold.rekeyChapter(exchange, renamed);
    expect(fold.isChapterOpen(exchange), isFalse);
    expect(fold.isChapterOpen(renamed), isTrue);
  });

  test('a moved folder carries its fold state along', () {
    fold
      ..expand(sidelines)
      ..expand(rare)
      ..openChapter(exchange);
    final moved = p.join(root, 'Old', 'Sidelines');
    fold.rekeyFolder(sidelines, moved);
    expect(fold.isExpanded(sidelines), isFalse);
    expect(fold.isExpanded(moved), isTrue);
    expect(fold.isExpanded(p.join(moved, 'Rare')), isTrue);
    expect(fold.isChapterOpen(p.join(moved, 'Exchange.pgn')), isTrue);
  });

  test('a deleted folder is forgotten with everything under it', () {
    fold
      ..expand(sidelines)
      ..expand(rare)
      ..openChapter(exchange)
      ..openChapter(advance);
    fold.forgetFolder(sidelines);
    expect(fold.isExpanded(sidelines), isFalse);
    expect(fold.isExpanded(rare), isFalse);
    expect(fold.isChapterOpen(exchange), isFalse);
    expect(fold.isChapterOpen(advance), isTrue);
  });

  test('clear forgets everything but the root stays open', () {
    fold
      ..expand(sidelines)
      ..openChapter(advance);
    fold.clear();
    expect(fold.isExpanded(sidelines), isFalse);
    expect(fold.isChapterOpen(advance), isFalse);
    expect(fold.isExpanded(root), isTrue);
  });
}
