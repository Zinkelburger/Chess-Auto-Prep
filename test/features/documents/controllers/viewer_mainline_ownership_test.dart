import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'package:chess_auto_prep/features/documents/controllers/viewer_game_controller.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

const sourceText =
    '[Event "Owned game"]\n[Result "*"]\n\n'
    '{Introduction} 1. e4 \$1 {Original} e5 ({Sideline introduction} 1... c5) 2. Nf3 *';

void main() {
  test(
    'load detaches parsed input and publishes immutable mainline/headers',
    () {
      final source = parsePgnGame(sourceText);
      final model = ViewerGameController()..load(source);
      final moves = model.moveHistory;
      final metadata = model.game!;
      final before = model.buildAnnotatedMovetext();
      source.headers['Event'] = 'Caller edit';
      source.comments.clear();
      final node = source.moves.children.single.data;
      node.comments!.add('Injected');
      node.nags!.add(7);
      source.moves.children.clear();
      expect(model.game!.headers['Event'], 'Owned game');
      expect(metadata.comments, ['Introduction']);
      expect(model.buildAnnotatedMovetext(), before);
      expect(() => metadata.headers.clear(), throwsUnsupportedError);
      expect(() => metadata.comments.clear(), throwsUnsupportedError);
      expect(() => moves.clear(), throwsUnsupportedError);
      expect(() => moves.first.comments!.clear(), throwsUnsupportedError);
      expect(() => moves.first.nags!.add(7), throwsUnsupportedError);
      final detached = moves.first.toPgnNodeData();
      detached.comments!.clear();
      detached.nags!.clear();
      expect(model.moveHistory.first.comments, ['Original']);
      expect(model.moveHistory.first.nags, [1]);
    },
  );

  test('navigation reuses the view; annotations share untouched moves', () {
    final model = ViewerGameController()..load(parsePgnGame(sourceText));
    final initial = model.moveHistory;
    final positions = model.mainline;
    model.goToMainLineMove(2);
    expect(model.moveHistory, same(initial));
    model.setMainlineComment(
      0,
      'Changed',
      expectedMove: initial.first.identity,
    );
    final edited = model.moveHistory;
    expect(edited, isNot(same(initial)));
    expect(edited.first.identity, same(initial.first.identity));
    expect(edited[1], same(initial[1]));
    expect(initial.first.comments, ['Original']);
    expect(edited.first.comments, ['Changed']);
    expect(model.mainline, same(positions));
    expect(model.setMainlineComment(0, 'Changed'), isFalse);
    expect(model.moveHistory, same(edited));
    model.toggleMainlineNag(0, 2, expectedMove: initial.first.identity);
    expect(model.moveHistory.first.nags, [2]);
    expect(edited.first.nags, [1]);
    model.goToMainLineMove(3);
    model.addMove('Nc6', editing: true, allowMainline: true);
    expect(model.moveHistory, hasLength(4));
    expect(model.moveHistory[1], same(initial[1]));
    expect(initial, hasLength(3));
    expect(model.mainline, same(positions));
    expect(model.mainline.reachablePlies, 4);
  });

  test('late comment and glyph commands cannot target a replacement game', () {
    final model = ViewerGameController()..load(parsePgnGame(sourceText));
    final old = model.moveHistory.first;
    final session = model.session;
    model.load(parsePgnGame('1. d4 d5 *'));
    expect(model.session, isNot(same(session)));
    expect(
      model.setMainlineComment(0, 'Stale', expectedMove: old.identity),
      isFalse,
    );
    expect(model.toggleMainlineNag(0, 2, expectedMove: old.identity), isFalse);
    expect(model.moveHistory.first.comments, isNull);
    expect(model.moveHistory.first.nags, isNull);
    expect(model.buildAnnotatedMovetext(), isNot(contains('Stale')));
  });

  test(
    'annotation adoption detaches input and retains move and cursor identity',
    () {
      final model = ViewerGameController()..load(parsePgnGame(sourceText));
      model.goToMainLineMove(2);
      final old = model.moveHistory;
      final memo = model.mainline;
      final session = model.session;
      final annotated = parsePgnGame(
        sourceText.replaceFirst('Original', 'New note'),
      );
      expect(model.adoptAnnotations(annotated), isTrue);
      final current = model.moveHistory;
      expect(model.session, same(session));
      expect(model.mainline, same(memo));
      expect(model.mainLineIndex, 2);
      expect(current.first.identity, same(old.first.identity));
      annotated.moves.children.single.data.comments!.clear();
      annotated.headers.clear();
      expect(current.first.comments, ['New note']);
      expect(model.game!.headers['Event'], 'Owned game');
      expect(old.first.comments, ['Original']);
      expect(
        model.setMainlineComment(
          0,
          'Retained draft',
          expectedMove: old.first.identity,
        ),
        isTrue,
      );
    },
  );

  test(
    'same SAN from another starting position is not an annotation update',
    () {
      final model = ViewerGameController()..load(parsePgnGame('1. e4 e5 *'));
      final before = model.moveHistory;
      final metadata = model.game;
      final afterD4 = Chess.initial.play(Chess.initial.parseSan('d4')!);
      final afterD5 = afterD4.play(afterD4.parseSan('d5')!);
      expect(
        model.adoptAnnotations(
          parsePgnGame('[FEN "${afterD5.fen}"]\n\n1. e4 {Wrong position} e5 *'),
        ),
        isFalse,
      );
      expect(model.moveHistory, same(before));
      expect(model.game, same(metadata));
      expect(model.startPosition.fen, Chess.initial.fen);
    },
  );

  test(
    'normalization and rejected adoption leave caller input and live flags intact',
    () {
      const review = '1. e4 {[%eval 0.1]} e5 {[%eval 3] [%pv c5,Nf3]} *';
      final parsed = parsePgnGame(review);
      final before = parsed.makePgn();
      final model = ViewerGameController()..load(parsed);
      expect(parsed.makePgn(), before);
      final flag = model.didMaterializeAnalysis;
      final live = model.moveHistory;
      expect(model.adoptAnnotations(parsePgnGame('1. d4 d5 *')), isFalse);
      expect(model.didMaterializeAnalysis, flag);
      expect(model.moveHistory, same(live));
    },
  );

  test(
    'serialization preserves variation introductions without changing source views',
    () {
      final model = ViewerGameController()..load(parsePgnGame(sourceText));
      final history = model.moveHistory;
      final text = model.buildAnnotatedMovetext();
      expect(text, contains('Sideline introduction'));
      expect(model.moveHistory, same(history));
      expect(model.buildAnnotatedMovetext(), text);
      final line = model.lineToVariationNode(
        model.variationsByPly[1]!.single,
        1,
      )!;
      final exported = model.buildLinePgn(line);
      expect(exported, contains('Sideline introduction'));
      expect(line.last.startingComments, ['Sideline introduction']);
    },
  );
}
