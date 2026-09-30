import 'schedule.dart';
import 'sitting.dart';
import 'training_line.dart';

/// How the Train tab lists a scope's lines.
enum LineOrder {
  /// Due first, then new, then learned, then what is left out: the order
  /// the lines come up in training.
  training,

  /// The order the file has them: the author's.
  course,

  /// The line the opponent most likely steers into first, as a generated
  /// chapter says; lines it says nothing about last.
  likely,
}

/// [lines] in [order], each band keeping the file's order among itself.
List<TrainingLine> ordered(
  List<TrainingLine> lines,
  LineOrder order, {
  required Map<LineKey, Review> reviews,
  required DateTime now,
}) {
  final int Function(TrainingLine a, TrainingLine b) compare = switch (order) {
    LineOrder.course => (a, b) => 0,
    LineOrder.training => (a, b) => _band(
      statusOf(a, reviews[a.key], now),
    ).compareTo(_band(statusOf(b, reviews[b.key], now))),
    LineOrder.likely => (a, b) => (b.likelihood ?? -1).compareTo(
      a.likelihood ?? -1,
    ),
  };
  // List.sort is not stable; the index settles ties in file order.
  final indexed = lines.indexed.toList()
    ..sort((a, b) {
      final by = compare(a.$2, b.$2);
      return by != 0 ? by : a.$1.compareTo(b.$1);
    });
  return [for (final (_, line) in indexed) line];
}

/// Whether [order] can put [lines] in an order of its own: the likeliest
/// first needs a file that says how likely its lines are.
bool canOrder(List<TrainingLine> lines, LineOrder order) =>
    order != LineOrder.likely || lines.any((l) => l.likelihood != null);

int _band(LineStatus status) => switch (status) {
  LineStatus.due => 0,
  LineStatus.untrained => 1,
  LineStatus.learned => 2,
  LineStatus.excluded => 3,
  LineStatus.game => 4,
};
