import 'package:flutter/material.dart';

import 'theme.dart';

/// The thin line that says something is running: [value] from 0 to 1 when
/// how far it has got is known, moving to and fro when not. It keeps its
/// height while nothing runs, so nothing under it moves when it starts.
class ProgressLine extends StatelessWidget {
  const ProgressLine({super.key, this.active = true, this.value});

  final bool active;
  final double? value;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: progressLineHeight,
    child: active
        ? LinearProgressIndicator(minHeight: progressLineHeight, value: value)
        : null,
  );
}
