/// Taking an engine pass's annotations onto the loaded game without moving
/// the reader: the same moves with new comments are adopted in place, and
/// anything that is not the same game is refused so the caller reloads.
library;

import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/documents/controllers/viewer_game_controller.dart';

const _header = '[Event "Pin"]\n[Result "*"]\n\n';
const _plain =
    '$_header'
    '1. e4 e5 (1... c5 {Sicilian}) 2. Nf3 Nc6 *\n';
const _annotated =
    '$_header'
    '1. e4 {[%eval 0.20]} e5 {[%eval 0.15]} (1... c5 {Sicilian}) '
    '2. Nf3 \$1 {[%eval 0.25]} Nc6 {[%eval 3.00] [%pv Nf6,Bc4]} *\n';

ViewerGameController _loaded(String pgn) {
  final model = ViewerGameController();
  model.load(parsePgnGame(pgn));
  return model;
}

void main() {
  test('nested annotations update in place and share untouched snapshots', () {
    final model = _loaded(
      '1. e4 (1. d4 {Root} d5 (1... Nf6 {Old} 2. c4 \$1 {Leaf}) 2. c4) (1. c4 e5) e5 (1... c5) *',
    );
    final before = model.variationsByPly;
    final root = before[0]!.first;
    final nested = root.children[1];
    final leaf = nested.children.single;
    model.goToAnalysisNode(leaf, 0);
    model.addMove('e6', editing: false, allowMainline: false);
    final scratch = model.analysisPath.last;
    final fen = model.currentPosition.fen;
    final session = model.session;
    expect(
      model.adoptAnnotations(
        parsePgnGame(
          '1. e4 (1. d4 d5 ({New introduction} 1... Nf6 {New} 2. c4 \$2 {Updated leaf}) 2. c4) (1. c4 e5) e5 (1... c5) *',
        ),
      ),
      isTrue,
    );
    final after = model.variationsByPly;
    expect(model.session, same(session));
    expect(model.currentPosition.fen, fen);
    expect(model.analysisPath.last, same(scratch));
    expect(model.findNodeById(leaf.id)!.comment, 'Updated leaf');
    expect(model.findNodeById(leaf.id)!.nags, [2]);
    expect(model.findNodeById(nested.id)!.startingComment, 'New introduction');
    expect(model.findNodeById(nested.id)!.comment, 'New');
    expect(model.findNodeById(root.id)!.comment, isNull);
    expect(after[0]![1], same(before[0]![1]));
    expect(after[1], same(before[1]));
    expect(after[0]!.first.children.first, same(root.children.first));
    expect(leaf.comment, 'Leaf');
    expect(leaf.nags, [1]);
    final saved = model.buildAnnotatedMovetext();
    expect(saved, contains('Updated leaf'));
    expect(saved, contains('New introduction'));
    expect(saved, isNot(contains('e6')));
  });

  for (final changed in [
    '1. e4 (1. d4 d5) e5 *',
    '1. e4 (1. d4 d5 2. Nf3) e5 *',
    '1. e4 (1. d4 d5 2. c4 (2. Nf3)) e5 *',
  ]) {
    test('a nested structural edit is refused atomically: $changed', () {
      final model = _loaded('1. e4 (1. d4 d5 2. c4) e5 *');
      final forest = model.variationsByPly;
      final moves = model.moveHistory;
      final session = model.session;
      final saved = model.buildAnnotatedMovetext();
      expect(model.adoptAnnotations(parsePgnGame(changed)), isFalse);
      expect(model.variationsByPly, same(forest));
      expect(model.moveHistory, same(moves));
      expect(model.session, same(session));
      expect(model.buildAnnotatedMovetext(), saved);
    });
  }

  test('only the referenced engine path may extend a stored branch', () {
    final model = _loaded('1. e4 (1. d4 d5) e5 *');
    final root = model.variationsByPly[0]!.single;
    model.goToAnalysisNode(root.children.single, 0);
    model.addMove('c4', editing: false, allowMainline: false);
    final scratch = model.analysisPath.last;
    model.addMove('e6', editing: false, allowMainline: false);
    final tail = model.analysisPath.last;
    expect(
      model.adoptAnnotations(
        parsePgnGame(
          '1. e4 {[%bestline d4,d5,c4]} (1. d4 d5 2. c4 (2. Nf3)) e5 *',
        ),
      ),
      isFalse,
    );
    expect(model.findNodeById(scratch.id)!.isEphemeral, isTrue);
    expect(
      model.adoptAnnotations(
        parsePgnGame('1. e4 {[%bestline d4,d5,c4]} (1. d4 d5 2. c4) e5 *'),
      ),
      isTrue,
    );
    expect(model.findNodeById(scratch.id)!.isEphemeral, isFalse);
    expect(model.analysisPath.last, same(tail));
    expect(model.hasEphemeralMoves, isTrue);
    final saved = model.buildAnnotatedMovetext();
    expect(saved, contains('c4'));
    expect(saved, isNot(contains('e6')));
  });

  test('duplicate sibling SANs keep separate identities and annotations', () {
    final model = _loaded('1. e4 (1. d4 {First} d5) (1. d4 {Second} d5) *');
    final before = model.variationsByPly[0]!;
    model.goToAnalysisNode(before[1], 0);
    expect(
      model.adoptAnnotations(
        parsePgnGame(
          '1. e4 (1. d4 {First updated} d5) (1. d4 {Second updated} d5) *',
        ),
      ),
      isTrue,
    );
    final after = model.variationsByPly[0]!;
    expect(after.map((n) => n.id), before.map((n) => n.id));
    expect(after.map((n) => n.comment), ['First updated', 'Second updated']);
    expect(after[0].id, isNot(after[1].id));
    expect(model.analysisPath.single.id, before[1].id);
    expect(model.buildAnnotatedMovetext(), contains('Second updated'));
  });

  test(
    'reordering nested siblings preserves cursor and unchanged node views',
    () {
      final model = _loaded('1. e4 (1. d4 d5 (1... Nf6)) *');
      final root = model.variationsByPly[0]!.single;
      model.goToAnalysisNode(root.children.first, 0);
      final fen = model.currentPosition.fen;
      expect(
        model.adoptAnnotations(parsePgnGame('1. e4 (1. d4 Nf6 (1... d5)) *')),
        isTrue,
      );
      final after = model.variationsByPly;
      expect(after[0]!.single.children.first, same(root.children[1]));
      expect(after[0]!.single.children[1], same(root.children.first));
      expect(model.currentPosition.fen, fen);
      expect(model.analysisPath.last.id, root.children.first.id);
      expect(
        model.adoptAnnotations(parsePgnGame('1. e4 (1. d4 Nf6 (1... d5)) *')),
        isTrue,
      );
      expect(model.variationsByPly, same(after));
    },
  );

  test('the same game with new comments is adopted where the reader is', () {
    final m = _loaded(_plain);
    m.goToMainLineMove(3);
    // Black to move after 2. Nf3: a scratch sideline instead of 2... Nc6.
    m.addMove('Nf6', editing: false, allowMainline: false);
    expect(m.hasEphemeralMoves, isTrue);

    final parsed = parsePgnGame(_annotated);
    expect(m.adoptAnnotations(parsed), isTrue);

    expect(m.mainLineIndex, 3);
    expect(
      m.hasEphemeralMoves,
      isFalse,
      reason: 'engine line reuses and saves the active scratch node',
    );
    expect(m.moveHistory[3].comments, ['[%eval 3.00] [%bestline Nf6,Bc4]']);
    expect(m.analysisPath.single.san, 'Nf6');
    expect(m.analysisPath.single.children.single.san, 'Bc4');
    expect(m.moveHistory[2].nags, [1]);
    expect(m.variationsByPly[1]!.where((n) => !n.isEphemeral), hasLength(1));
  });

  test('a different mainline is refused', () {
    final m = _loaded(_plain);
    expect(
      m.adoptAnnotations(
        parsePgnGame(
          '$_header'
          '1. e4 e5 2. Nf3 Nf6 *',
        ),
      ),
      isFalse,
    );
    expect(
      m.adoptAnnotations(
        parsePgnGame(
          '$_header'
          '1. e4 e5 2. Nf3 *',
        ),
      ),
      isFalse,
    );
    expect(m.moveHistory[0].comments, isNull, reason: 'left untouched');
  });

  test('a different set of stored sidelines is refused', () {
    final m = _loaded(_plain);
    expect(
      m.adoptAnnotations(
        parsePgnGame(
          '$_header'
          '1. e4 {[%eval 0.20]} e5 2. Nf3 Nc6 *',
        ),
      ),
      isFalse,
      reason: 'the Sicilian sideline is gone',
    );
    expect(
      m.adoptAnnotations(
        parsePgnGame(
          '$_header'
          '1. e4 e5 (1... c5) (1... e6) 2. Nf3 Nc6 *',
        ),
      ),
      isFalse,
      reason: 'a sideline was added',
    );
  });
}
