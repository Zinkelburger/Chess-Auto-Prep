import 'package:flutter/material.dart';

/// A bounded name in a list, with the complete name available on hover or
/// long press. Keep the original text for search, selection and semantics.
class ItemTitle extends StatelessWidget {
  const ItemTitle(this.text, {super.key, this.style, this.maxLines = 2});

  final String text;
  final TextStyle? style;
  final int maxLines;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: text,
    child: Text(
      text,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: style,
    ),
  );
}
