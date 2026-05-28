/// Expandable trap details under a candidate move row.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import 'package:chess_auto_prep/features/traps/models/trap_line_info.dart';
import 'package:chess_auto_prep/features/traps/services/trap_index_service.dart';
import 'package:chess_auto_prep/features/browse/services/candidate_service.dart';

class ExpandedTrapList extends StatefulWidget {
  final CandidateMove candidate;
  final TrapIndexService? trapIndex;
  final void Function(TrapLineInfo) onTrapGo;

  const ExpandedTrapList({
    super.key,
    required this.candidate,
    required this.trapIndex,
    required this.onTrapGo,
  });

  @override
  State<ExpandedTrapList> createState() => _ExpandedTrapListState();
}

class _ExpandedTrapListState extends State<ExpandedTrapList> {
  int _currentTrapIdx = 0;

  List<TrapLineInfo> get _traps {
    if (widget.trapIndex == null || widget.candidate.treeNode == null) {
      return [];
    }
    final node = widget.candidate.treeNode!;
    final movePath = <String>[];
    var current = node;
    while (current.parent != null) {
      movePath.insert(0, current.moveSan);
      current = current.parent!;
    }
    return widget.trapIndex!.trapsInLine(movePath);
  }

  @override
  Widget build(BuildContext context) {
    final traps = _traps;
    if (traps.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
        child: Text(
          'No trap details available',
          style: TextStyle(fontSize: 11, color: Colors.grey[500]),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.04),
        border: const Border(
          left: BorderSide(width: 2, color: AppColors.warning),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < traps.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Text(
                    i < traps.length - 1 ? '├' : '└',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${traps[i].popularMove}? played ${(traps[i].popularProb * 100).toStringAsFixed(0)}%, '
                      'loses ${(traps[i].evalDiffCp / 100).toStringAsFixed(1)} pawns',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  InkWell(
                    onTap: () => widget.onTrapGo(traps[i]),
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.grey.withAlpha(80)),
                      ),
                      child: const Text('Go',
                          style: TextStyle(fontSize: 10)),
                    ),
                  ),
                ],
              ),
            ),
          if (traps.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _currentTrapIdx > 0
                        ? () {
                            setState(() => _currentTrapIdx--);
                            widget.onTrapGo(traps[_currentTrapIdx]);
                          }
                        : null,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Prev',
                        style: TextStyle(fontSize: 10)),
                  ),
                  TextButton(
                    onPressed: _currentTrapIdx < traps.length - 1
                        ? () {
                            setState(() => _currentTrapIdx++);
                            widget.onTrapGo(traps[_currentTrapIdx]);
                          }
                        : null,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Next',
                        style: TextStyle(fontSize: 10)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
