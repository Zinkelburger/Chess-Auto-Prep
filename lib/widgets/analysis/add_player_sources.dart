/// The three ways a player gets into Player Analysis, named once.
///
/// The screen used to stack three floating action buttons ("Import
/// Opponents", "Load from disk", "Download New") over the list *and* repeat
/// two of them as buttons in the empty state — five controls for three
/// actions, none of whose labels said whether they downloaded, opened a file,
/// or did both. Every label now starts with a verb and says where the games
/// come from, and each source is written down exactly once here so the menu
/// and the empty state can never drift apart.
library;

import 'package:flutter/material.dart';

import '../../theme/app_text_styles.dart';

/// Where a player's games come from.
enum AddPlayerSource {
  /// Fetch one player's games from their chess.com / lichess account.
  download(
    icon: Icons.cloud_download_outlined,
    label: 'Download a player’s games',
    detail: 'From their Chess.com or Lichess username',
  ),

  /// Read games out of PGN files already on this computer.
  pgnFiles(
    icon: Icons.folder_open_outlined,
    label: 'Open PGN files',
    detail: 'Games you already have saved on this computer',
  ),

  /// Download every entrant named in an opponent-list file, in one pass.
  opponentList(
    icon: Icons.groups_outlined,
    label: 'Add a whole tournament field',
    detail: 'Downloads everyone named in an opponent-list file',
  );

  const AddPlayerSource({
    required this.icon,
    required this.label,
    required this.detail,
  });

  final IconData icon;

  /// What tapping it does, as a verb phrase.
  final String label;

  /// One line of "where do the games come from", shown wherever there is
  /// room for it.
  final String detail;

  /// Menu wording: the trailing ellipsis promises a dialog, not an
  /// immediate download.
  String get menuLabel => '$label…';
}

/// The single "add a player" control: one button, one menu, three sources.
class AddPlayerButton extends StatelessWidget {
  const AddPlayerButton({super.key, required this.onSelected});

  final ValueChanged<AddPlayerSource> onSelected;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      builder: (context, controller, _) => FilledButton.icon(
        key: const Key('add-player-button'),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.add, size: 18),
        label: const Text('Add player'),
      ),
      menuChildren: [
        for (final source in AddPlayerSource.values)
          MenuItemButton(
            leadingIcon: Icon(source.icon, size: 20),
            onPressed: () => onSelected(source),
            child: SizedBox(
              width: 300,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(source.menuLabel),
                    const SizedBox(height: 2),
                    Text(source.detail, style: AppTextStyles.caption),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The same three sources spelled out as a list, for the first run — when
/// there is nothing to pick, the options should be on the screen rather than
/// hidden one tap deep in a menu.
class AddPlayerSourceList extends StatelessWidget {
  const AddPlayerSourceList({super.key, required this.onSelected});

  final ValueChanged<AddPlayerSource> onSelected;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final source in AddPlayerSource.values) ...[
            if (source != AddPlayerSource.values.first)
              const Divider(height: 1),
            ListTile(
              key: Key('add-player-${source.name}'),
              leading: Icon(source.icon),
              title: Text(source.menuLabel),
              subtitle: Text(source.detail),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () => onSelected(source),
            ),
          ],
        ],
      ),
    );
  }
}
