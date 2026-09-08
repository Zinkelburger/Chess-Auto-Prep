import 'package:flutter/material.dart';
import '../../core/pgn/pgn_workspace.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

class PgnWorkspaceBar extends StatelessWidget {
  const PgnWorkspaceBar({
    super.key,
    required this.workspace,
    required this.onSelect,
    required this.onClose,
    required this.addButton,
  });
  final PgnWorkspace workspace;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;
  final Widget addButton;

  @override
  Widget build(BuildContext context) {
    if (workspace.openTabs.length < 2) return const SizedBox.shrink();
    return Container(
      height: 38,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final id in workspace.openTabs)
                    DragTarget<int>(
                      onWillAcceptWithDetails: (d) => id != 0 && d.data != id,
                      onAcceptWithDetails: (d) => workspace.move(d.data, id),
                      builder: (context, candidates, rejected) =>
                          Draggable<int>(
                            data: id,
                            maxSimultaneousDrags: id == 0 ? 0 : 1,
                            feedback: Material(
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: Text(workspace.titles[id]!),
                              ),
                            ),
                            child: Container(
                              constraints: const BoxConstraints(maxWidth: 220),
                              decoration: BoxDecoration(
                                color:
                                    workspace.index == id ||
                                        candidates.isNotEmpty
                                    ? AppColors.surfaceElevated
                                    : null,
                                border: Border(
                                  bottom: BorderSide(
                                    width: 2,
                                    color: workspace.index == id
                                        ? AppColors.onSurfaceMuted
                                        : Colors.transparent,
                                  ),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: Tooltip(
                                      message: workspace.titles[id]!,
                                      child: InkWell(
                                        onTap: () => onSelect(id),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 9,
                                          ),
                                          child: Text(
                                            workspace.titles[id]!,
                                            overflow: TextOverflow.ellipsis,
                                            style: AppTextStyles.muted.copyWith(
                                              fontWeight: FontWeight.w400,
                                              color: workspace.index == id
                                                  ? AppColors.ink
                                                  : AppColors.onSurfaceMuted,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (id != 0)
                                    IconButton(
                                      onPressed: () => onClose(id),
                                      tooltip:
                                          'Close ${workspace.titles[id]} tab',
                                      icon: const Icon(Icons.close, size: 14),
                                      color: AppColors.onSurfaceMuted,
                                      padding: EdgeInsets.zero,
                                      constraints:
                                          const BoxConstraints.tightFor(
                                            width: 28,
                                            height: 30,
                                          ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                    ),
                ],
              ),
            ),
          ),
          addButton,
        ],
      ),
    );
  }
}
