import 'package:chess_auto_prep/chess_core/moves/move_tree_view.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_game_view.dart';
import 'package:chess_auto_prep/features/documents/models/viewer_document_layout.dart';
import 'package:chess_auto_prep/models/move_tree.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

ViewerDocumentLayout layout({
  List<PgnMoveSnapshot> moves = const [],
  Map<int, List<MoveNodeView>> variations = const {},
  bool expandAll = true,
  Set<int> selected = const {},
  Map<int, bool> visibility = const {},
  int? frontier,
  bool Function(MoveNodeView, int)? visible,
}) => ViewerDocumentLayout(
  moves: moves,
  variations: variations,
  visible: visible ?? (_, _) => true,
  proseReference: (_, _) => false,
  inlineVariation: (_) => false,
  visibility: visibility,
  selectedPath: selected,
  expandAll: expandAll,
  frontier: frontier ?? moves.length,
  engineRoots: const {},
);

MoveNode node(String san, {String? comment}) =>
    MoveNode(san: san, fen: Chess.initial.fen, comment: comment);

void main() {
  test('principal child precedes alternatives, then the line resumes', () {
    final root = node('d4');
    final d5 = node('d5');
    final nf6 = node('Nf6', comment: 'Indian systems');
    root.children.addAll([d5, nf6]);
    d5.children.add(node('c4'));
    nf6.children.add(node('c4'));
    final indexed = layout(
      variations: {
        0: [root],
      },
    );
    final rows = indexed.rows.whereType<ViewerVariationRow>().toList();
    expect(rows.expand((r) => r.nodes).map((n) => n.san), [
      'd4',
      'd5',
      'Nf6',
      'c4',
      'c4',
    ]);
    expect(rows.map((r) => r.depth), [1, 2, 2, 1]);
    expect(rows.map((r) => r.ply), [0, 1, 2, 2]);
    for (final row in rows) {
      for (final n in row.nodes) {
        expect(indexed.rows[indexed.nodeRow(n.id)!], same(row));
      }
      expect(indexed.rows[indexed.indexOfKey(row.key)!], same(row));
    }
  });

  test('20000 annotated mainline plies retain their identity and frontier', () {
    final moves = List.generate(
      20000,
      (i) => PgnMoveSnapshot.capture(
        PgnNodeData(san: 'Nf3', comments: i % 10 == 0 ? ['Note $i'] : null),
      ),
    );
    final indexed = layout(moves: moves);
    expect(
      indexed.rows.whereType<ViewerMainlineRow>().every(
        (r) => r.end - r.start <= ViewerDocumentLayout.maxRunLength,
      ),
      isTrue,
    );
    for (final ply in [0, 9000, 19999]) {
      final row = indexed.rows[indexed.mainlineRow(ply)!] as ViewerMainlineRow;
      expect(ply, inInclusiveRange(row.start, row.end - 1));
    }
    final hidden = layout(moves: moves, frontier: 11);
    expect(hidden.mainlineRow(10), isNotNull);
    expect(hidden.mainlineRow(11), isNull);
  });

  test(
    '20000 nested branches index iteratively and fold without losing heads',
    () {
      final root = node('d4');
      var cursor = root;
      final ids = <int>{root.id};
      for (var i = 0; i < 20000; i++) {
        final next = node('c4');
        cursor.children.addAll([node('e4'), next]);
        cursor = next;
        ids.add(next.id);
      }
      final indexed = layout(
        variations: {
          0: [root],
        },
      );
      expect(indexed.nodeRow(cursor.id), isNotNull);
      expect(indexed.rows.whereType<ViewerVariationRow>().last.depth, 20001);
      final folded = layout(
        variations: {
          0: [root],
        },
        expandAll: false,
      );
      expect(folded.nodeRow(cursor.id), isNull);
      expect(folded.rows.whereType<ViewerVariationRow>().last.open, isFalse);
      final selected = layout(
        variations: {
          0: [root],
        },
        expandAll: false,
        selected: ids,
      );
      expect(selected.nodeRow(cursor.id), isNotNull);
    },
  );

  test(
    'reveal filters principal children and alternatives before indexing',
    () {
      final root = node('d4');
      final first = node('d5');
      final scratch = node('Nf6');
      root.children.addAll([first, scratch]);
      final indexed = layout(
        variations: {
          0: [root],
        },
        visible: (n, _) => n.id != first.id,
      );
      expect(indexed.nodeRow(first.id), isNull);
      expect(indexed.nodeRow(scratch.id), isNotNull);
    },
  );
}
