import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/workspace/gap_walk.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

/// A White chapter: 1. e4 answered against e5 and c5, nothing against e6.
const chapter = '''
// Color: White

[Event "Open"]
[Result "*"]

1. e4 e5 2. Nf3 *

[Event "Sicilian"]
[Result "*"]

1. e4 c5 *
''';

/// What "the model" says Black plays after 1. e4, and White's choice at the
/// start, keyed by the position part of the FEN.
const shares = <String, Map<String, double>>{
  // After 1. e4.
  'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b': {
    'e7e5': 0.5,
    'c7c5': 0.3,
    'e7e6': 0.15,
    'a7a6': 0.05,
  },
  // After 1. e4 e5 2. Nf3.
  'rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b': {
    'b8c6': 0.8,
    'g8f6': 0.2,
  },
};

Future<Map<String, double>?> model(Fen fen) async {
  final key = fen.value.split(' ').take(2).join(' ');
  return shares[key];
}

void main() {
  late GameTree tree;

  setUp(() {
    tree = parseChapter(name: 'Main', text: chapter).tree;
  });

  Future<GapWalk> walk({double floor = 0.1}) async => (await walkGaps(
    tree: tree,
    side: Side.white,
    floor: floor,
    shares: model,
    overtaken: () => false,
  ))!;

  test('lists what the opponent plays often and the chapter does not '
      'answer, most reached first', () async {
    final found = await walk();
    // e6 (15%) is missing after 1. e4; after 1. e4 e5 2. Nf3 both Nc6 (40%)
    // and Nf6 (10%) are missing; after 1. e4 c5 (30%) the chapter stops.
    expect(found.gaps.map((gap) => gap.reach.toStringAsFixed(2)), [
      '0.40',
      '0.30',
      '0.15',
      '0.10',
    ]);
    final first = found.gaps.first as MissingReply;
    expect(first.san, 'Nc6');
    expect(first.at, NodePath.of([0, 0, 0]));
    expect(found.gaps[1], isA<DeadEnd>());
    expect(found.gaps[1].at, NodePath.of([0, 1]));
    expect((found.gaps[2] as MissingReply).san, 'e6');
    expect(found.covered, closeTo(0.05, 1e-9));
  });

  test('a reply under the floor is neither followed nor a gap', () async {
    final found = await walk(floor: 0.2);
    expect(found.gaps.map((gap) => gap.reach.toStringAsFixed(2)), [
      '0.40',
      '0.30',
    ]);
    expect(found.reach[NodePath.of([0, 0])], 0.5);
    expect(found.reach.containsKey(NodePath.of([0, 1])), isTrue);
  });

  test('a position the model cannot answer is counted, not a gap', () async {
    final found = await walkGaps(
      tree: tree,
      side: Side.white,
      floor: 0.01,
      shares: (fen) async => null,
      overtaken: () => false,
    );
    expect(found!.gaps, isEmpty);
    expect(found.positionsAsked, 1);
    expect(found.positionsUnanswered, 1);
  });

  test('an overtaken walk answers nothing', () async {
    var calls = 0;
    final found = await walkGaps(
      tree: tree,
      side: Side.white,
      floor: 0.01,
      shares: (fen) async {
        calls++;
        return model(fen);
      },
      overtaken: () => calls > 0,
    );
    expect(found, isNull);
  });

  test('castling is found in the tree whichever way it is spelled', () {
    final position = const Fen(
      'r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4',
    );
    final tree = parseChapter(
      name: 'x',
      text: '[Event "x"]\n[FEN "${position.value}"]\n[SetUp "1"]\n\n4. O-O *\n',
    ).tree;
    expect(indexOfReply(position, tree.children, 'e1g1'), 0);
    expect(indexOfReply(position, tree.children, 'e1h1'), 0);
    expect(indexOfReply(position, tree.children, 'd2d3'), -1);
  });
}
