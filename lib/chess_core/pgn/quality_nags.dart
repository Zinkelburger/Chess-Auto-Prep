/// PGN move-quality rules independent of glyph styling.
bool isQualityNag(int id) => id >= 1 && id <= 6;

/// Toggle move-quality NAG [nagId] on a move's [current] NAG list, returning
/// the new list. The six quality glyphs (ids 1–6) are mutually exclusive:
/// setting one clears the others, and setting the one already present removes
/// it. Non-quality NAGs are preserved. The result may be empty (callers store
/// `null` for an empty NAG list).
List<int> toggleQualityNag(List<int>? current, int nagId) {
  final existing = current ?? const <int>[];
  final others = [
    for (final n in existing)
      if (!isQualityNag(n)) n,
  ];
  final alreadyOn = existing.contains(nagId);
  return <int>[if (!alreadyOn && isQualityNag(nagId)) nagId, ...others];
}
