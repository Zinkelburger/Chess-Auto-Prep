import 'package:chess_auto_prep/v2/ui/error_bar.dart';
import 'package:flutter/material.dart';

/// The window's status bar over [child], as the shell puts it: what a panel
/// says through [StatusScope] shows above it, with its button and Close.
class StatusHost extends StatefulWidget {
  const StatusHost({super.key, required this.child});

  final Widget child;

  @override
  State<StatusHost> createState() => _StatusHostState();
}

class _StatusHostState extends State<StatusHost> {
  ({String text, StatusAction? action})? _said;

  void _say(String text, {StatusAction? action}) {
    if (!mounted) return;
    setState(() => _said = (text: text, action: action));
  }

  @override
  Widget build(BuildContext context) => StatusScope(
    say: _say,
    child: Column(
      children: [
        if (_said case final said?)
          ErrorBar(
            said.text,
            action: said.action,
            onClose: () => setState(() => _said = null),
          ),
        Expanded(child: widget.child),
      ],
    ),
  );
}
