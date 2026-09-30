import 'chapter_line.dart';
import 'game_text.dart';

/// Names are the existing viewer reading-session protocol.
enum GameOrder {
  fileOrder('File order'),
  dateDesc('Newest first'),
  ratingDesc('Rating high'),
  ratingAsc('Rating low');

  const GameOrder(this.label);
  final String label;
}

List<int> orderGames(
  List<ChapterLine> lines,
  Iterable<int> indexes,
  GameOrder order,
) {
  if (order == GameOrder.fileOrder) return indexes.toList()..sort();
  final rows = [
    for (final i in indexes)
      (index: i, date: _date(lines[i]), rating: _rating(lines[i])),
  ];
  rows.sort((a, b) {
    final int compared;
    if (order == GameOrder.dateDesc) {
      compared = b.date.compareTo(a.date);
    } else if (a.rating == null || b.rating == null) {
      compared = a.rating == b.rating ? 0 : (a.rating == null ? 1 : -1);
    } else {
      compared = order == GameOrder.ratingDesc
          ? b.rating!.compareTo(a.rating!)
          : a.rating!.compareTo(b.rating!);
    }
    return compared == 0 ? a.index.compareTo(b.index) : compared;
  });
  return [for (final row in rows) row.index];
}

String _date(ChapterLine line) {
  final date =
      tagValue(line.tags, 'UTCDate') ?? tagValue(line.tags, 'Date') ?? '';
  return date.startsWith('?') ? '' : date.replaceAll('?', '0');
}

double? _rating(ChapterLine line) {
  final values = [
    for (final tag in ['WhiteElo', 'BlackElo'])
      if (double.tryParse(tagValue(line.tags, tag) ?? '') case final v?
          when v.isFinite && v > 0)
        v,
  ];
  return values.isEmpty ? null : values.reduce((a, b) => a + b) / values.length;
}
