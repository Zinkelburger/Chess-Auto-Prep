import 'package:flutter/material.dart';

import '../../chess/bughouse/expectimax.dart';
import '../../chess/bughouse/hivemind.dart';
import '../../chess/bughouse/table.dart';
import '../../ui/field_row.dart';
import '../../ui/move_notation.dart';
import '../../ui/number_field.dart';
import '../../ui/theme.dart';
import 'expectimax_search.dart';

/// Practical-move rankings, with the selected move's weighted human replies.
class BughouseExpectimaxPanel extends StatelessWidget {
  const BughouseExpectimaxPanel({super.key, required this.search});
  final BughouseExpectimaxSearch search;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: search,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _controls(context),
        Text(
          '${search.board.label} · no clocks or sitting',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const Text('White / Black expectimax · scores from White’s side.'),
        const Text('Partner board fixed; captures still feed its pockets.'),
        SizedBox(
          height: labStatusHeight,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              search.status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        if (search.problem case final problem?)
          SelectableText(
            problem,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        _header(context),
        Expanded(
          child: ListView.builder(
            itemCount: search.rows.length,
            itemExtent: labTableRowHeight,
            itemBuilder: (context, i) => _row(context, search.rows[i]),
          ),
        ),
        if (search.selected case final row?) _replies(context, row),
      ],
    ),
  );

  Widget _controls(BuildContext context) => Column(
    children: [
      Row(
        children: [
          FilledButton(
            key: const ValueKey('bughouse-expectimax-run'),
            onPressed: search.running ? search.stop : search.start,
            child: Text(search.running ? 'Stop' : 'Expectimax'),
          ),
          const SizedBox(width: Space.s),
          Expanded(
            child: SegmentedButton<BoardNumber>(
              segments: [
                for (final b in BoardNumber.values)
                  ButtonSegment(value: b, label: Text(b.label)),
              ],
              selected: {search.board},
              showSelectedIcon: false,
              onSelectionChanged: search.running
                  ? null
                  : (value) => search.configure(board: value.single),
            ),
          ),
        ],
      ),
      ExpansionTile(
        title: Text('${search.plies} plies · ${search.nodes} Hivemind nodes'),
        tilePadding: EdgeInsets.zero,
        children: [
          _number(
            'Search plies',
            search.plies,
            2,
            4,
            (n) => search.configure(plies: n),
          ),
          _number(
            'Hivemind nodes',
            search.nodes,
            100,
            30000,
            (n) => search.configure(nodes: n),
          ),
          const Text(
            'Hivemind’s best move + top 4 policy moves above 1%. Unsearched reply mass retains the searched value. Stops at 10,000 positions.',
          ),
        ],
      ),
    ],
  );

  Widget _number(
    String label,
    int value,
    int min,
    int max,
    ValueChanged<int> change,
  ) => IgnorePointer(
    ignoring: search.running,
    child: FieldRow(
      label: label,
      child: NumberField(
        label: label,
        value: value,
        step: max > 100 ? 100 : 1,
        min: min,
        max: max,
        onChanged: change,
      ),
    ),
  );

  Widget _header(BuildContext context) => Container(
    height: labTableRowHeight,
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    padding: const EdgeInsets.symmetric(horizontal: Space.xs),
    child: Row(
      children: [
        const Expanded(child: Text('Move')),
        _heading(
          'Played',
          'Calibrated CrazyAra policy: a proxy for human moves, not a human-trained model.',
          searchShareWidth,
        ),
        _heading(
          'Eval',
          'Searched Hivemind evaluation from White’s side. Its own scale, not pawns or win odds.',
          searchValueWidth,
        ),
        _heading(
          'Exp W',
          'Expectimax White: White chooses best continuations, Black follows human probabilities. Higher is better for White.',
          searchValueWidth,
        ),
        _heading(
          'Exp B',
          'Expectimax Black: Black chooses best continuations, White follows human probabilities. Lower is better for Black.',
          searchValueWidth,
        ),
      ],
    ),
  );

  Widget _heading(String text, String hint, double width) => Tooltip(
    message: hint,
    child: SizedBox(
      width: width,
      child: Text(text, textAlign: TextAlign.right),
    ),
  );

  Widget _numberCell(String text, double width) => SizedBox(
    width: width,
    child: Text(text, style: monoText, textAlign: TextAlign.right),
  );

  Widget _row(BuildContext context, BughouseBranch row) => MouseRegion(
    onEnter: (_) => search.lab.preview.value = {search.board: row.move.uci},
    onExit: (_) => search.lab.preview.value = null,
    child: Material(
      color: identical(search.selected, row)
          ? Theme.of(context).colorScheme.surfaceContainerHighest
          : Colors.transparent,
      child: InkWell(
        onTap: () => search.select(row),
        onDoubleTap: () => search.lab.play(search.board, row.move.uci),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.xs),
          child: Row(
            children: [
              Expanded(
                child: Text(displaySan(context, row.move.san), style: monoText),
              ),
              _numberCell(
                '${(row.probability * 100).toStringAsFixed(0)}%',
                searchShareWidth,
              ),
              _numberCell(_score(row.child.evaluation), searchValueWidth),
              _numberCell(_score(row.child.white), searchValueWidth),
              _numberCell(_score(row.child.black), searchValueWidth),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _replies(BuildContext context, BughouseBranch row) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Divider(),
      Row(
        children: [
          Expanded(
            child: Text(
              'After ${row.move.san} · replies',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: () => search.lab.play(search.board, row.move.uci),
            child: const Text('Play move'),
          ),
        ],
      ),
      for (final reply in row.child.branches.take(5))
        SizedBox(
          height: labTableRowHeight,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  displaySan(context, reply.move.san),
                  style: monoText,
                ),
              ),
              _numberCell(
                '${(reply.probability * 100).toStringAsFixed(1)}%',
                searchShareWidth,
              ),
              _numberCell(
                _score(
                  reply.child.prepared(search.lab.position.turn(search.board)),
                ),
                searchValueWidth,
              ),
            ],
          ),
        ),
      Text(
        '${(row.child.coverage * 100).toStringAsFixed(1)}% reply mass searched · ${row.child.branches.length} replies',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      Text(
        'CrazyAra calibrated on FICS · Hivemind depth ${row.child.depth ?? 'mate'}, ${row.child.nodes} nodes',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );
}

String _score(double q) => _signed(scoreOf(q));
String _signed(double value) => value.abs() < .005
    ? '0.00'
    : '${value > 0 ? '+' : ''}${value.toStringAsFixed(2)}';
