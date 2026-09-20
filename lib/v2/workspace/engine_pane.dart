import 'package:flutter/material.dart';

import '../chess/pv_text.dart';
import '../ui/theme.dart';
import 'engine_analysis.dart';

/// The engine's lines for the position on the board, Lichess style: the
/// best score large, then one fixed-height row per MultiPV line so the
/// pane never jumps as lines arrive. A row shows the line the engine
/// numbered with that MultiPV, and stays blank while it has none. A switch
/// turns the engine on and off.
class EnginePane extends StatelessWidget {
  const EnginePane({super.key, required this.analysis});

  final EngineAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: analysis,
      builder: (context, _) {
        final snapshot = analysis.snapshot;
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.m,
            Space.s,
            Space.s,
            Space.s,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(analysis: analysis),
              for (var multiPv = 1; multiPv <= analysis.multiPv; multiPv++)
                _LineRow(
                  text: snapshot == null ? null : _row(snapshot, multiPv),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The score column, the same above and in every row so the moves line up.
const _scoreWidth = 64.0;

/// What the [multiPv]-th row reads, or null when this snapshot has no such
/// line yet.
({String score, String moves})? _row(AnalysisSnapshot snapshot, int multiPv) {
  final line = snapshot.line(multiPv);
  if (line == null) return null;
  return (score: line.score.text, moves: pvText(snapshot.fen, line.pv));
}

class _Header extends StatelessWidget {
  const _Header({required this.analysis});

  final EngineAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final best = analysis.snapshot?.best;
    final (String status, Color? colour) = switch (analysis.state) {
      EngineOff() => ('Engine off', null),
      EngineStarting() => ('Starting…', null),
      EngineFailed(:final reason) => (reason, scheme.error),
      EngineRunning(:final name) => (
        best == null ? name : 'depth ${best.depth} · $name',
        null,
      ),
    };
    return Row(
      children: [
        SizedBox(
          width: _scoreWidth,
          child: Text(best?.score.text ?? '', style: scoreText),
        ),
        Expanded(
          child: Text(
            status,
            style: text.bodySmall?.copyWith(color: colour),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Tooltip(
          message: 'Engine',
          child: Switch(
            value: analysis.enabled,
            onChanged: (on) => on ? analysis.enable() : analysis.disable(),
          ),
        ),
      ],
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({required this.text});

  final ({String score, String moves})? text;

  static const height = 22.0;

  @override
  Widget build(BuildContext context) {
    final line = text;
    if (line == null) return const SizedBox(height: height);
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height,
      child: Row(
        children: [
          SizedBox(
            width: _scoreWidth,
            child: Text(
              line.score,
              style: monoText.copyWith(color: scheme.onSurface),
            ),
          ),
          Expanded(
            child: Text(
              line.moves,
              style: monoText.copyWith(color: scheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
