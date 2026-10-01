import 'package:flutter/material.dart';

import 'theme.dart';

/// A quiet button that folds a group of settings away under it and back:
/// its fixed [label], and a chevron saying which way it will go.
class FoldButton extends StatelessWidget {
  const FoldButton({
    super.key,
    required this.label,
    required this.unfolded,
    required this.onPressed,
  });

  final String label;
  final bool unfolded;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        Icon(
          unfolded ? Icons.expand_less : Icons.expand_more,
          size: IconSize.menu,
        ),
      ],
    ),
  );
}
