/// Searchable chapter navigation for the PGN collection counter.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_text_styles.dart';
import 'common/list_search_field.dart';
import 'game_nav_item.dart';

/// A chapter's games in the current filtered/sorted navigation order.
class GameNavChapter {
  final String? name;
  final List<int> gameIndices;

  const GameNavChapter({required this.name, required this.gameIndices});

  String get label => name ?? 'Other games';

  /// Repeated, non-contiguous chapter titles share one row. Null titles get
  /// a separate row so illustrative games remain reachable too.
  static List<GameNavChapter> fromGames(List<GameNavItem> games) {
    final groups = <String?, List<int>>{};
    for (var i = 0; i < games.length; i++) {
      (groups[games[i].chapter] ??= []).add(i);
    }
    return [
      for (final entry in groups.entries)
        GameNavChapter(
          name: entry.key,
          gameIndices: List.unmodifiable(entry.value),
        ),
    ];
  }
}

/// Returns an index in [games], never a chapter ordinal or a file index.
Future<int?> showGameChapterDialog({
  required BuildContext context,
  required List<GameNavItem> games,
  required int currentIndex,
}) => showDialog<int>(
  context: context,
  builder: (_) => GameChapterDialog(
    chapters: GameNavChapter.fromGames(games),
    currentIndex: currentIndex,
  ),
);

class GameChapterDialog extends StatefulWidget {
  final List<GameNavChapter> chapters;
  final int currentIndex;

  const GameChapterDialog({
    super.key,
    required this.chapters,
    required this.currentIndex,
  });

  @override
  State<GameChapterDialog> createState() => _GameChapterDialogState();
}

class _GameChapterDialogState extends State<GameChapterDialog> {
  String _query = '';

  List<GameNavChapter> get _visible => [
    for (final chapter in widget.chapters)
      if (matchesSearch(_query, chapter.label)) chapter,
  ];

  void _select(GameNavChapter chapter) {
    if (!mounted || chapter.gameIndices.isEmpty) return;
    Navigator.pop(context, chapter.gameIndices.first);
  }

  void _close() {
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: Dialog(
        child: SizedBox(
          width: 480,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Browse chapters',
                        style: AppTextStyles.title,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close chapter browser',
                      onPressed: _close,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ListSearchField(
                  hintText: 'Search chapters...',
                  autofocus: true,
                  onChanged: (value) {
                    if (!mounted) return;
                    setState(() => _query = value);
                  },
                  onSubmitted: () {
                    if (!mounted) return;
                    final matches = _visible;
                    if (matches.isNotEmpty) _select(matches.first);
                  },
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 360),
                    child: visible.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(16),
                            child: Text(
                              'No matching chapters',
                              style: AppTextStyles.muted,
                            ),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            itemCount: visible.length,
                            itemBuilder: (context, index) {
                              final chapter = visible[index];
                              final count = chapter.gameIndices.length;
                              final isCurrent = chapter.gameIndices.contains(
                                widget.currentIndex,
                              );
                              return ListTile(
                                selected: isCurrent,
                                title: Text(
                                  chapter.label,
                                  style: AppTextStyles.body,
                                ),
                                subtitle: Text(
                                  '$count game${count == 1 ? '' : 's'} · starts at game ${chapter.gameIndices.first + 1}',
                                  style: AppTextStyles.caption,
                                ),
                                trailing: isCurrent
                                    ? const Icon(
                                        Icons.check,
                                        semanticLabel: 'Current chapter',
                                      )
                                    : null,
                                onTap: () => _select(chapter),
                              );
                            },
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
