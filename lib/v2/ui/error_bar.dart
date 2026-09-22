import 'package:flutter/material.dart';

import 'theme.dart';

/// One line across the window under the top bar, in the error colour: what
/// the last action could not do, until the next thing said replaces it.
class ErrorBar extends StatelessWidget {
  const ErrorBar(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(
        horizontal: Space.l,
        vertical: Space.s,
      ),
      child: Text(text, style: TextStyle(color: scheme.onErrorContainer)),
    );
  }
}
