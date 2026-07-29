import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../theme/app_colors.dart';

class AppModeMenuButton extends StatelessWidget {
  const AppModeMenuButton({super.key, this.tooltip = 'Switch mode'});

  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, child) {
        return PopupMenuButton<AppMode>(
          icon: const Icon(Icons.view_module),
          tooltip: appState.isRepertoireGenerating
              ? 'Locked — repertoire generation in progress'
              : tooltip,
          enabled: !appState.isRepertoireGenerating,
          onSelected: appState.setMode,
          itemBuilder: (context) => [
            for (final mode in AppMode.values)
              _buildMenuItem(
                mode: mode,
                icon: _iconFor(mode),
                label: mode.label,
                isSelected: appState.currentMode == mode,
              ),
          ],
        );
      },
    );
  }

  IconData _iconFor(AppMode mode) => switch (mode) {
    AppMode.tactics => Icons.psychology,
    AppMode.positionAnalysis => Icons.analytics,
    AppMode.repertoire => Icons.library_books,
    AppMode.repertoireTrainer => Icons.school,
    AppMode.pgnViewer => Icons.menu_book,
    AppMode.study => Icons.edit_note,
  };

  PopupMenuItem<AppMode> _buildMenuItem({
    required AppMode mode,
    required IconData icon,
    required String label,
    required bool isSelected,
  }) {
    return PopupMenuItem<AppMode>(
      value: mode,
      child: Row(
        children: [
          Icon(icon),
          const SizedBox(width: 12),
          Text(label),
          if (isSelected)
            const Padding(
              padding: EdgeInsets.only(left: 12),
              child: Icon(Icons.check, size: 16, color: AppColors.success),
            ),
        ],
      ),
    );
  }
}
