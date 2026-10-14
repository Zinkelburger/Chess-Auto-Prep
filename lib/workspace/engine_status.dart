import '../engines/engine_line.dart';

/// Depths from here on are not a depth a player can read anything into:
/// Stockfish, once it has found a mate, runs its iterations out to 245 in
/// moments. The line's `#` says what happened; the depth is left out.
const shownDepthLimit = 100;

/// The engine pane's status while the engine runs: how deep the best line
/// is, how fast and how far the engine has searched, which engine it is,
/// and, last, why it is not the engine the user chose.
///
/// `Depth 24 · 12 MN/s · 345M nodes · Stockfish 19`
String engineRunningStatus(String name, EngineLine? best, {String? notice}) => [
  if (best != null && best.depth > 0 && best.depth < shownDepthLimit)
    'Depth ${best.depth}',
  if (best?.nps case final nps? when nps > 0) speedText(nps),
  if (best?.nodes case final nodes? when nodes > 0) '${countText(nodes)} nodes',
  name,
  ?notice,
].join(' · ');

/// Nodes per second as an engine GUI writes them: `850 kN/s`, `1.2 MN/s`,
/// `12 MN/s`.
String speedText(int nps) => nps < 1000000
    ? '${(nps / 1000).round()} kN/s'
    : '${_short(nps / 1000000)} MN/s';

/// A large count in a few characters: `950`, `56k`, `1.2M`, `345M`, `2.1G`.
String countText(int n) => switch (n) {
  < 1000 => '$n',
  < 1000000 => '${_short(n / 1000)}k',
  < 1000000000 => '${_short(n / 1000000)}M',
  _ => '${_short(n / 1000000000)}G',
};

/// One decimal below ten, none above: `1.2`, `12`, `345`.
String _short(double value) =>
    value < 10 ? value.toStringAsFixed(1) : '${value.round()}';
