import 'package:flutter/material.dart';

/// Keeps the board and panes mounted while a chapter is read and parsed.
/// The previous chapter stays visible, but cannot accept edits until the
/// controller has atomically installed the requested chapter.
class RepertoireLoadingFrame extends StatelessWidget {
  const RepertoireLoadingFrame({
    super.key,
    required this.isLoading,
    required this.child,
  });

  final bool isLoading;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        AbsorbPointer(
          absorbing: isLoading,
          child: ExcludeFocus(excluding: isLoading, child: child),
        ),
        if (isLoading)
          const Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: LinearProgressIndicator(
              minHeight: 2,
              semanticsLabel: 'Opening chapter',
            ),
          ),
      ],
    );
  }
}
