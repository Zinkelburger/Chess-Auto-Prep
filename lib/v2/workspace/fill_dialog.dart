import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../storage/settings.dart';
import '../ui/theme.dart';
import 'fill_gaps.dart';

/// Asks what a fill should do — three numbers — and answers the request,
/// or null when the user backed out. The rating and the cover rule start
/// from the Replies settings, so a fill prepares for the opponent the table
/// is already showing.
Future<FillRequest?> showFillDialog(
  BuildContext context, {
  required int elo,
  required int onceIn,
  int depth = 8,
}) => showDialog<FillRequest>(
  context: context,
  builder: (context) => _FillDialog(elo: elo, onceIn: onceIn, depth: depth),
);

/// How deep a fill may look: one ply, or as far as the pure search goes.
const minFillDepth = 1;
const maxFillDepth = 64;

class _FillDialog extends StatefulWidget {
  const _FillDialog({
    required this.elo,
    required this.onceIn,
    required this.depth,
  });

  final int elo;
  final int onceIn;
  final int depth;

  @override
  State<_FillDialog> createState() => _FillDialogState();
}

class _FillDialogState extends State<_FillDialog> {
  late final _elo = TextEditingController(text: '${widget.elo}');
  late final _depth = TextEditingController(text: '${widget.depth}');
  late final _onceIn = TextEditingController(text: '${widget.onceIn}');
  String? _eloProblem;
  String? _depthProblem;
  String? _onceInProblem;

  @override
  void dispose() {
    _elo.dispose();
    _depth.dispose();
    _onceIn.dispose();
    super.dispose();
  }

  /// [text] as a number within [min]..[max], or null with the problem set.
  int? _number(String text, int min, int max) {
    final value = int.tryParse(text.trim());
    return value != null && value >= min && value <= max ? value : null;
  }

  void _submit() {
    final elo = _number(_elo.text, Settings.minElo, Settings.maxElo);
    final depth = _number(_depth.text, minFillDepth, maxFillDepth);
    final onceIn = _number(
      _onceIn.text,
      Settings.minCoverOnceIn,
      Settings.maxCoverOnceIn,
    );
    setState(() {
      _eloProblem = elo == null
          ? '${Settings.minElo} to ${Settings.maxElo}'
          : null;
      _depthProblem = depth == null ? '$minFillDepth to $maxFillDepth' : null;
      _onceInProblem = onceIn == null
          ? '${Settings.minCoverOnceIn} to ${Settings.maxCoverOnceIn}'
          : null;
    });
    if (elo == null || depth == null || onceIn == null) return;
    Navigator.of(
      context,
    ).pop(FillRequest(elo: elo, depthPlies: depth, onceIn: onceIn));
  }

  Widget _field(
    TextEditingController box,
    String label,
    String? problem, {
    bool autofocus = false,
  }) => TextField(
    controller: box,
    autofocus: autofocus,
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    decoration: InputDecoration(labelText: label, errorText: problem),
    onSubmitted: (_) => _submit(),
  );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('Fill gaps from here'),
      content: SizedBox(
        width: nameDialogWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _field(_elo, 'Opponent rating', _eloProblem, autofocus: true),
            const SizedBox(height: Space.m),
            _field(_depth, 'How deep (half-moves)', _depthProblem),
            const SizedBox(height: Space.m),
            _field(_onceIn, 'Cover replies met once in', _onceInProblem),
            const SizedBox(height: Space.l),
            Text('Engine + human model', style: text.labelSmall),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Fill')),
      ],
    );
  }
}
