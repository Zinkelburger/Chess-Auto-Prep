import 'package:flutter/material.dart';

import '../shortcut_tooltip.dart';

/// Body shown in the tools column when the loaded repertoire has no lines
/// yet: large tappable cards for each way of adding lines, so the entry
/// points are discoverable without hunting through the toolbar.
class RepertoireEmptyState extends StatelessWidget {
  const RepertoireEmptyState({
    super.key,
    required this.onGenerate,
    this.onBuildFromGames,
    this.onImportPgnFile,
    this.onImportPgnPaste,
    this.onDismiss,
  });

  final VoidCallback? onGenerate;
  final VoidCallback? onBuildFromGames;
  final VoidCallback? onImportPgnFile;
  final VoidCallback? onImportPgnPaste;

  /// Swaps in the normal tools column (sticky for the session).
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.account_tree_outlined,
                  size: 40, color: Colors.grey[600]),
              const SizedBox(height: 12),
              Text(
                'This repertoire is empty',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Add lines to start training against them.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.grey[500]),
              ),
              const SizedBox(height: 20),
              if (onGenerate != null)
                _EmptyStateCard(
                  icon: Icons.auto_awesome,
                  title: 'Generate',
                  shortcut: 'G',
                  description: 'Build lines with the engine and an opponent '
                      'model from the current position.',
                  onTap: onGenerate!,
                ),
              if (onBuildFromGames != null)
                _EmptyStateCard(
                  icon: Icons.download_for_offline_outlined,
                  title: 'From my games',
                  description: 'Download your games and draft a repertoire '
                      'from the lines you actually play.',
                  onTap: onBuildFromGames!,
                ),
              if (onImportPgnFile != null)
                _EmptyStateCard(
                  icon: Icons.file_open,
                  title: 'Import PGN file',
                  shortcut: 'I',
                  description: 'Load lines from a PGN file on disk.',
                  onTap: onImportPgnFile!,
                ),
              if (onImportPgnPaste != null)
                _EmptyStateCard(
                  icon: Icons.paste,
                  title: 'Paste PGN',
                  description: 'Paste PGN text from the clipboard.',
                  onTap: onImportPgnPaste!,
                ),
              const SizedBox(height: 12),
              Text(
                'You can also just play moves on the board to explore.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.grey[600]),
              ),
              if (onDismiss != null)
                TextButton(
                  onPressed: onDismiss,
                  child: const Text('Skip — show the analysis tabs'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyStateCard extends StatelessWidget {
  const _EmptyStateCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
    this.shortcut,
  });

  final IconData icon;
  final String title;
  final String description;
  final String? shortcut;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final card = Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey[800]!, width: 0.5),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 22, color: theme.colorScheme.primary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: Colors.grey[500]),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right, size: 18, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
    if (shortcut == null) return card;
    return ShortcutTooltip(
      description: title,
      shortcut: shortcut!,
      child: card,
    );
  }
}
