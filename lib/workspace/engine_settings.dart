import 'dart:async';

import 'package:flutter/material.dart';

import '../storage/settings.dart';
import '../storage/settings_store.dart';
import '../ui/theme.dart';

/// How many rows the engine's settings take in place of its lines.
const engineSettingRows = 3;

/// The table sizes the memory slider stops at: powers of two, as an engine
/// takes them, up to the most the setting accepts.
const engineMemoryStops = [16, 32, 64, 128, 256, 512, 1024, 2048, 4096];

/// The engine's own settings, shown in the engine pane where its lines
/// are: how many lines, how many cores, how much memory. One slider a row,
/// in the lines' gutter, written to the same settings Settings ▸ Engine
/// shows. A slider writes when it is let go, so a drag across it restarts
/// the engine once rather than at every stop.
class EngineSettingsView extends StatelessWidget {
  const EngineSettingsView({
    super.key,
    required this.settings,
    required this.coresAvailable,
  });

  final SettingsStore settings;

  /// The cores this computer has: the most the engine may be given.
  final int coresAvailable;

  void _change(Settings Function(Settings now) edit) =>
      unawaited(settings.update(edit(settings.value)));

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final s = settings.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SliderRow(
              label: 'Lines',
              stops: [for (var n = 1; n <= Settings.maxLines; n++) n],
              value: s.engineLines,
              format: (n) => '$n',
              onChanged: (n) => _change((now) => now.copyWith(engineLines: n)),
            ),
            _SliderRow(
              label: 'CPU cores',
              stops: [for (var n = 1; n <= coresAvailable; n++) n],
              value: s.engineCores,
              format: (n) => '$n of $coresAvailable',
              onChanged: (n) => _change((now) => now.copyWith(engineCores: n)),
            ),
            _SliderRow(
              label: 'Memory',
              stops: engineMemoryStops,
              value: s.engineMemoryMb,
              format: (n) => '$n MB',
              onChanged: (n) =>
                  _change((now) => now.copyWith(engineMemoryMb: n)),
            ),
          ],
        );
      },
    );
  }
}

/// A name in the score gutter, a slider over the moves' column, and the
/// value where a line's depth would be. The slider rests on the stop
/// nearest [value]; the words say [value] itself, or the stop under a drag.
class _SliderRow extends StatefulWidget {
  const _SliderRow({
    required this.label,
    required this.stops,
    required this.value,
    required this.format,
    required this.onChanged,
  });

  final String label;
  final List<int> stops;
  final int value;
  final String Function(int value) format;
  final ValueChanged<int> onChanged;

  @override
  State<_SliderRow> createState() => _SliderRowState();
}

class _SliderRowState extends State<_SliderRow> {
  /// The stop under the thumb while it is dragged; null at rest.
  int? _dragged;

  int get _nearest {
    var best = 0;
    for (var i = 1; i < widget.stops.length; i++) {
      final distance = (widget.stops[i] - widget.value).abs();
      if (distance < (widget.stops[best] - widget.value).abs()) best = i;
    }
    return best;
  }

  void _drag(double at) {
    if (!mounted) return;
    setState(() => _dragged = at.round());
  }

  void _let(double at) {
    if (!mounted) return;
    setState(() => _dragged = null);
    final chosen = widget.stops[at.round()];
    if (chosen != widget.value) widget.onChanged(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final last = widget.stops.length - 1;
    final at = _dragged ?? _nearest;
    final shown = _dragged == null ? widget.value : widget.stops[at];
    return SizedBox(
      height: engineRowHeight,
      child: Row(
        children: [
          SizedBox(
            width:
                engineScoreWidth +
                MediaQuery.textScalerOf(context).scale(engineDepthWidth),
            child: Padding(
              padding: const EdgeInsets.only(left: Space.s),
              child: Text(widget.label, style: text.labelSmall, maxLines: 1),
            ),
          ),
          Expanded(
            child: Semantics(
              label: widget.label,
              child: Slider(
                value: at.toDouble(),
                max: last < 1 ? 1 : last.toDouble(),
                divisions: last < 1 ? null : last,
                semanticFormatterCallback: (at) =>
                    widget.format(widget.stops[at.round().clamp(0, last)]),
                onChanged: last < 1 ? null : _drag,
                onChangeEnd: last < 1 ? null : _let,
              ),
            ),
          ),
          SizedBox(
            width: MediaQuery.textScalerOf(context).scale(engineDepthWidth),
            child: Text(
              widget.format(shown),
              style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              textAlign: TextAlign.right,
              maxLines: 1,
            ),
          ),
          const SizedBox(width: Space.s),
        ],
      ),
    );
  }
}
