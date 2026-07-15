/// Shared move-sequence filter widget for PGN slice/search.
///
/// Finds games containing specific SAN moves in order, with configurable
/// gap tolerance between groups separated by `[gap]`. All state lives on the
/// [SliceFilterController] passed in by the host.
library;

import 'package:flutter/material.dart';

import '../../core/slice_filter_controller.dart';

class SequenceFilter extends StatelessWidget {
  final SliceFilterController controller;

  const SequenceFilter({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, controller.sequenceText]),
      builder: (context, _) => _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final error = controller.sequenceError;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Move Sequence Filter',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: Colors.grey[300],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Find games containing specific moves in order. '
          'Use [gap] between groups that need not be consecutive.',
          style: TextStyle(color: Colors.grey[500], fontSize: 11),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller.sequenceText,
          decoration: InputDecoration(
            hintText: 'e.g.  d5 e5 [gap] f6',
            hintStyle: TextStyle(color: Colors.grey[600], fontSize: 12),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 10,
            ),
            border: const OutlineInputBorder(),
            suffixIcon: controller.sequenceText.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    onPressed: () {
                      controller.sequenceText.clear();
                      controller.validateSequence();
                    },
                  )
                : null,
            suffixIconConstraints: const BoxConstraints(
              minWidth: 32,
              minHeight: 28,
            ),
          ),
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          onChanged: (_) => controller.validateSequence(),
          onSubmitted: (_) => controller.validateSequence(),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            if (error != null)
              Expanded(
                child: Text(
                  error,
                  style: const TextStyle(fontSize: 11, color: Colors.red),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              )
            else
              const Spacer(),
            Text(
              'Max gap: ',
              style: TextStyle(fontSize: 12, color: Colors.grey[400]),
            ),
            SizedBox(
              width: 40,
              child: TextField(
                controller: controller.gapText,
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 8,
                  ),
                  border: OutlineInputBorder(),
                ),
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                keyboardType: TextInputType.number,
                onChanged: (_) => controller.sequenceGapChanged(),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              'ply',
              style: TextStyle(fontSize: 12, color: Colors.grey[400]),
            ),
          ],
        ),
      ],
    );
  }
}
