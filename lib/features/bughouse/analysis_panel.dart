import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import 'archive_moves.dart';
import 'bughouse_lab.dart';
import 'expectimax_panel.dart';
import 'expectimax_search.dart';
import 'lab_panel.dart';
import 'table_search.dart';

class BughouseAnalysisPanel extends StatelessWidget {
  const BughouseAnalysisPanel({
    super.key,
    required this.lab,
    required this.search,
    required this.archive,
    this.expectimax,
  });
  final BughouseLab lab;
  final TableSearch search;
  final ArchiveMoves archive;
  final BughouseExpectimaxSearch? expectimax;

  @override
  Widget build(BuildContext context) {
    final practical = expectimax;
    if (practical == null)
      return LabPanel(lab: lab, search: search, archive: archive);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('Expectimax')),
            ButtonSegment(value: false, label: Text('Engine analysis')),
          ],
          selected: {lab.expectimaxOn},
          showSelectedIcon: false,
          onSelectionChanged: (values) {
            final value = values.single;
            practical.stop();
            if (value && search.engineOn) search.toggleEngine();
            lab.showExpectimax(value);
          },
        ),
        const SizedBox(height: Space.s),
        Expanded(
          child: lab.expectimaxOn
              ? BughouseExpectimaxPanel(search: practical)
              : LabPanel(lab: lab, search: search, archive: archive),
        ),
      ],
    );
  }
}
