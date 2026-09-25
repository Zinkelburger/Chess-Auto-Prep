import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import 'game_book.dart';

/// Both comparison views label retained results while their inputs are stale.
class BookComparisonStatus extends StatelessWidget {
  const BookComparisonStatus({super.key, required this.book});

  final GameBook book;

  @override
  Widget build(BuildContext context) {
    if (!book.stale) return const SizedBox.shrink();
    final problem = book.problem;
    return Padding(
      padding: const EdgeInsets.all(Space.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (book.state is BookChecked) const Text('Previous comparison'),
          if (book.checking) const Text('Updating comparison…'),
          if (problem != null) ...[
            Text(
              'Could not update comparison: $problem',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            TextButton(onPressed: book.recheck, child: const Text('Retry')),
          ],
        ],
      ),
    );
  }
}
