import 'dart:async';

import 'package:flutter/material.dart';

/// A tooltip that **always** waits [waitDuration] before appearing, even when
/// the user moves quickly between tooltipped widgets.  Flutter's built-in
/// [Tooltip] has a global warm-up that skips the delay after one tooltip was
/// recently shown; this widget avoids that by managing its own hover timer and
/// overlay entry independently.
class TacticsDelayedTooltip extends StatefulWidget {
  const TacticsDelayedTooltip({
    super.key,
    required this.message,
    required this.waitDuration,
    required this.child,
  });

  final String message;
  final Duration waitDuration;
  final Widget child;

  @override
  State<TacticsDelayedTooltip> createState() => _TacticsDelayedTooltipState();
}

class _TacticsDelayedTooltipState extends State<TacticsDelayedTooltip>
    with SingleTickerProviderStateMixin {
  OverlayEntry? _overlayEntry;
  Timer? _showTimer;
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeIn,
    );
  }

  @override
  void dispose() {
    _hideTooltip();
    _fadeController.dispose();
    super.dispose();
  }

  void _onEnter(PointerEvent _) {
    _showTimer?.cancel();
    _showTimer = Timer(widget.waitDuration, _showTooltip);
  }

  void _onExit(PointerEvent _) {
    _showTimer?.cancel();
    _showTimer = null;
    _hideTooltip();
  }

  void _showTooltip() {
    if (!mounted) return;
    _overlayEntry?.remove();

    final overlay = Overlay.of(context);
    final renderBox = context.findRenderObject() as RenderBox;
    final offset = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;

    _overlayEntry = OverlayEntry(
      builder: (_) => Positioned(
        left: offset.dx + size.width / 2 - _estimateWidth(widget.message) / 2,
        top: offset.dy + size.height + 4,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: IgnorePointer(
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  widget.message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(_overlayEntry!);
    _fadeController.forward(from: 0);
  }

  void _hideTooltip() {
    _fadeController.reset();
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  double _estimateWidth(String text) {
    return text.length * 8.0 + 16;
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: _onEnter,
      onExit: _onExit,
      child: widget.child,
    );
  }
}

/// Tooltip styled for keyboard shortcut hints.
Widget tacticsShortcutTooltip({
  required String message,
  required Widget child,
}) {
  return TacticsDelayedTooltip(
    message: message,
    waitDuration: const Duration(seconds: 1),
    child: child,
  );
}
