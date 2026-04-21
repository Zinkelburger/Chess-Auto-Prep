import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';

class AppModeMenuButton extends StatelessWidget {
  const AppModeMenuButton({
    super.key,
    this.tooltip = 'Switch mode',
  });

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
            _buildMenuItem(
              mode: AppMode.tactics,
              icon: Icons.psychology,
              label: 'Tactics',
              isSelected: appState.currentMode == AppMode.tactics,
            ),
            _buildMenuItem(
              mode: AppMode.positionAnalysis,
              icon: Icons.analytics,
              label: 'Player Analysis',
              isSelected: appState.currentMode == AppMode.positionAnalysis,
            ),
            _buildMenuItem(
              mode: AppMode.repertoire,
              icon: Icons.library_books,
              label: 'Repertoire Builder',
              isSelected: appState.currentMode == AppMode.repertoire,
            ),
            _buildMenuItem(
              mode: AppMode.repertoireTrainer,
              icon: Icons.school,
              label: 'Repertoire Trainer',
              isSelected: appState.currentMode == AppMode.repertoireTrainer,
            ),
          ],
        );
      },
    );
  }

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
              child: Icon(Icons.check, size: 16, color: Colors.green),
            ),
        ],
      ),
    );
  }
}
