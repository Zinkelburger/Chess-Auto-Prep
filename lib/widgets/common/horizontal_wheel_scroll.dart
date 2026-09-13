import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A horizontal strip that also accepts an ordinary vertical mouse wheel.
/// Native horizontal trackpad events remain owned by the Scrollable. At an
/// edge, vertical events can continue to a surrounding vertical scroll view.
class HorizontalWheelScroll extends StatefulWidget {
  const HorizontalWheelScroll({
    super.key,
    required this.child,
    this.controller,
    this.padding,
    this.reverse = false,
  });

  final Widget child;
  final ScrollController? controller;
  final EdgeInsetsGeometry? padding;
  final bool reverse;

  @override
  State<HorizontalWheelScroll> createState() => _HorizontalWheelScrollState();
}

class _HorizontalWheelScrollState extends State<HorizontalWheelScroll> {
  final _ownedController = ScrollController();
  ScrollController get _controller => widget.controller ?? _ownedController;

  @override
  void dispose() {
    _ownedController.dispose();
    super.dispose();
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        event.scrollDelta.dx != 0 ||
        event.scrollDelta.dy == 0 ||
        !_controller.hasClients) {
      return;
    }
    final position = _controller.position;
    final reverse = position.axisDirection == AxisDirection.left;
    final delta = event.scrollDelta.dy * (reverse ? -1 : 1);
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      if (!mounted || !_controller.hasClients) return;
      _controller.position.pointerScroll(delta);
    });
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerSignal: _onPointerSignal,
    child: SingleChildScrollView(
      controller: _controller,
      scrollDirection: Axis.horizontal,
      reverse: widget.reverse,
      padding: widget.padding,
      child: widget.child,
    ),
  );
}
