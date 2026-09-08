import 'package:flutter/material.dart';
import '../../models/pgn_game_entry.dart';
import '../../theme/app_text_styles.dart';

/// Collection operations have room to explain their scope and choose games.
class PgnCollectionPanel extends StatefulWidget {
  const PgnCollectionPanel({
    super.key,
    required this.games,
    required this.onSaveStudy,
    required this.onExportPgn,
    required this.onExportScid,
    required this.onTree,
  });
  final List<PgnGameEntry> games;
  final ValueChanged<List<PgnGameEntry>> onSaveStudy;
  final VoidCallback onExportPgn, onExportScid, onTree;
  @override
  State<PgnCollectionPanel> createState() => _PgnCollectionPanelState();
}

class _PgnCollectionPanelState extends State<PgnCollectionPanel> {
  final Set<PgnGameEntry> _selected = {};
  @override
  void didUpdateWidget(covariant PgnCollectionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _selected.removeWhere((g) => !widget.games.contains(g));
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.games.length} games in the current filter',
              style: AppTextStyles.body,
            ),
            const SizedBox(height: 4),
            const Text(
              'Browse the combined opening tree or work with games across the collection. Saved and exported games keep all their variations.',
              style: AppTextStyles.muted,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  onPressed: widget.onTree,
                  icon: const Icon(Icons.account_tree_outlined, size: 18),
                  label: const Text('Opening tree'),
                ),
                TextButton(
                  onPressed: widget.onExportPgn,
                  child: const Text('Export PGN…'),
                ),
                TextButton(
                  onPressed: widget.onExportScid,
                  child: const Text('Export Scid…'),
                ),
              ],
            ),
            const Text(
              'Export actions use all games in the current filter.',
              style: AppTextStyles.caption,
            ),
          ],
        ),
      ),
      const Divider(height: 1),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value:
                      widget.games.isNotEmpty &&
                      _selected.length == widget.games.length,
                  onChanged: (v) {
                    if (!mounted) return;
                    setState(() {
                      _selected.clear();
                      if (v == true) _selected.addAll(widget.games);
                    });
                  },
                ),
                Text(
                  '${_selected.length} selected',
                  style: AppTextStyles.muted,
                ),
              ],
            ),
            TextButton(
              onPressed: _selected.isEmpty
                  ? null
                  : () => widget.onSaveStudy(
                      widget.games.where(_selected.contains).toList(),
                    ),
              child: const Text('Save selection to study…'),
            ),
          ],
        ),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: widget.games.length,
          itemBuilder: (_, i) {
            final game = widget.games[i];
            return CheckboxListTile(
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: _selected.contains(game),
              title: Text(
                '${i + 1}. ${game.label}',
                style: AppTextStyles.muted,
              ),
              onChanged: (v) {
                if (!mounted) return;
                setState(() {
                  if (v == true) {
                    _selected.add(game);
                  } else {
                    _selected.remove(game);
                  }
                });
              },
            );
          },
        ),
      ),
    ],
  );
}
