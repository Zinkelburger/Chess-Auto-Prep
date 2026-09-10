import 'package:flutter/material.dart';

import '../../models/repertoire_line.dart';
import '../../services/repertoire_review_service.dart';
import '../../theme/app_text_styles.dart';
import '../../utils/fen_utils.dart' show plyFromFen;
import '../../utils/movetext_builder.dart';
import '../../utils/time_format.dart';
import '../common/list_search_field.dart';

/// Searchable attempt history inside the trainer's existing side pane.
class TrainingMistakesPanel extends StatefulWidget {
  const TrainingMistakesPanel({
    super.key,
    required this.service,
    required this.sourcePaths,
    required this.lines,
    required this.onClose,
    required this.onRead,
  });
  final RepertoireReviewService service;
  final Set<String> sourcePaths;
  final List<RepertoireLine> lines;
  final VoidCallback onClose;
  final void Function(RepertoireLine line, int moveIndex) onRead;
  @override
  State<TrainingMistakesPanel> createState() => _TrainingMistakesPanelState();
}

class _TrainingMistakesPanelState extends State<TrainingMistakesPanel> {
  late final _attempts = widget.service.loadAttempts();
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final source = widget.sourcePaths.length == 1
        ? widget.sourcePaths.single
        : '';
    final linesById = {
      for (final line in widget.lines)
        (line.sourcePath ?? source, line.persistedId): line,
    };
    RepertoireLine? lineFor(Map<String, dynamic> row) =>
        linesById[(row['repertoireId'], row['lineId'])];
    return Column(
      children: [
        Row(
          children: [
            IconButton(
              onPressed: widget.onClose,
              icon: const Icon(Icons.arrow_back),
              tooltip: 'Back to training',
            ),
            const Text('Mistakes', style: AppTextStyles.title),
          ],
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: ListSearchField(
            hintText: 'Search lines or moves…',
            onChanged: (value) {
              if (mounted) setState(() => _query = value.toLowerCase());
            },
          ),
        ),
        Expanded(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _attempts,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const Center(child: Text('Could not load mistakes.'));
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final rows = snapshot.data!.reversed
                  .where(
                    (row) =>
                        row['correct'] == false &&
                        widget.sourcePaths.contains(row['repertoireId']) &&
                        '${lineFor(row)?.qualifiedName ?? ''} ${row['playedSan']} ${row['expectedSan']}'
                            .toLowerCase()
                            .contains(_query),
                  )
                  .toList();
              if (rows.isEmpty) {
                return Center(
                  child: Text(
                    _query.isEmpty
                        ? 'No recorded mistakes.'
                        : 'No mistakes match your search.',
                  ),
                );
              }
              return ListView.builder(
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final row = rows[index];
                  final line = lineFor(row);
                  final fen = row['fen'] as String?;
                  final ply = fen == null
                      ? row['moveIndex'] as int
                      : plyFromFen(fen);
                  final when = DateTime.tryParse('${row['timestampUtc']}');
                  final phase = switch (row['phase']) {
                    'learning' => 'Learn',
                    'replaying' => 'Correction',
                    _ => 'Practice',
                  };
                  final time = when == null
                      ? ''
                      : ' · ${formatTimeAgo(when.toLocal())}';
                  return ListTile(
                    title: Text(
                      'Book: ${formatMoveAtPly(ply, row['expectedSan'] as String)}  ·  '
                      'You: ${formatMoveAtPly(ply, row['playedSan'] as String)}',
                      style: AppTextStyles.body.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    subtitle: Text(
                      '${line?.qualifiedName ?? row['lineId']}\n'
                      '$phase$time',
                      style: AppTextStyles.caption,
                    ),
                    isThreeLine: true,
                    trailing: line == null
                        ? null
                        : const Icon(Icons.chevron_right),
                    onTap: line == null
                        ? null
                        : () {
                            if (!mounted) return;
                            widget.onRead(line, row['moveIndex'] as int);
                          },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
