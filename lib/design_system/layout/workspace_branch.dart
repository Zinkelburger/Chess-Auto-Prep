import 'package:flutter/material.dart';

/// Retains a mode's keyboard destination while an IndexedStack parks its view.
/// Inactive branches cannot consume keyboard input or join focus traversal.
class WorkspaceBranch extends StatefulWidget {
  const WorkspaceBranch({super.key, required this.active, required this.child});
  final bool active;
  final Widget child;

  @override
  State<WorkspaceBranch> createState() => _WorkspaceBranchState();
}

class _WorkspaceBranchState extends State<WorkspaceBranch> {
  final _scope = FocusScopeNode();
  FocusNode? _lastFocus;

  @override
  void didUpdateWidget(WorkspaceBranch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active && _scope.hasFocus) {
      _lastFocus = FocusManager.instance.primaryFocus;
    }
    if (!oldWidget.active && widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.active) return;
        // A root dialog owns the keyboard until it closes.
        if (ModalRoute.of(context)?.isCurrent == false) return;
        final target = _lastFocus;
        if (target?.context != null && target!.canRequestFocus) {
          target.requestFocus();
        } else {
          _scope.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusScope(
    node: _scope,
    canRequestFocus: widget.active,
    descendantsAreFocusable: widget.active,
    descendantsAreTraversable: widget.active,
    child: widget.child,
  );
}
