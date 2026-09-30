import 'package:chess_auto_prep/ui/status_bar.dart';
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
  ({String text, StatusAction? action, bool problem})? _said;

  void _say(String text, {StatusAction? action, bool problem = true}) {
    if (!mounted) return;
    setState(() => _said = (text: text, action: action, problem: problem));
  }

  @override
  Widget build(BuildContext context) => StatusScope(
    say: _say,
    child: Column(
      children: [
        if (_said case final said?)
          StatusBar(
            said.text,
            action: said.action,
            problem: said.problem,
            onClose: () => setState(() => _said = null),
          ),
        Expanded(child: widget.child),
      ],
    ),
  );
}
