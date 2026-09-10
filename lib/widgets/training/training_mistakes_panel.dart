import 'package:flutter/material.dart';

import '../../models/repertoire_line.dart';
import '../../services/repertoire_review_service.dart';
import '../../theme/app_text_styles.dart';
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

  RepertoireLine? _line(Map<String, dynamic> row) {
    for (final line in widget.lines) {
      if (line.persistedId == row['lineId'] &&
          (line.sourcePath == null || line.sourcePath == row['repertoireId'])) {
        return line;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => Column(
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
                      '${_line(row)?.qualifiedName ?? ''} ${row['playedSan']} ${row['expectedSan']}'
                          .toLowerCase()
                          .contains(_query),
                )
                .toList();
            if (rows.isEmpty) {
              return const Center(child: Text('No recorded mistakes.'));
            }
            return ListView.builder(
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final row = rows[index];
                final line = _line(row);
                return ListTile(
                  title: Text(
                    'Book: ${row['expectedSan']}  ·  You: ${row['playedSan']}',
                    style: AppTextStyles.body.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    '${line?.qualifiedName ?? row['lineId']}\n'
                    '${row['phase']} · ${row['timestampUtc']}',
                    style: AppTextStyles.caption,
                  ),
                  isThreeLine: true,
                  trailing: line == null
                      ? null
                      : const Icon(Icons.chevron_right),
                  onTap: line == null
                      ? null
                      : () => widget.onRead(line, row['moveIndex'] as int),
                );
              },
            );
          },
        ),
      ),
    ],
  );
}
