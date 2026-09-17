import 'package:flutter/widgets.dart';
import '../controllers/document_close_coordinator.dart';

class DocumentCloseScope extends InheritedWidget {
  const DocumentCloseScope({
    super.key,
    required this.coordinator,
    required super.child,
  });
  final DocumentCloseCoordinator coordinator;
  static DocumentCloseCoordinator? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<DocumentCloseScope>()
      ?.coordinator;
  @override
  bool updateShouldNotify(DocumentCloseScope oldWidget) =>
      coordinator != oldWidget.coordinator;
}

/// Registers the owner for exactly as long as this document remains mounted,
/// including while its workspace branch is hidden.
class DocumentCloseRegistration extends StatefulWidget {
  const DocumentCloseRegistration({
    super.key,
    required this.revision,
    required this.prepare,
    required this.child,
  });
  final Object Function() revision;
  final Future<DocumentCloseApproval?> Function() prepare;
  final Widget child;
  @override
  State<DocumentCloseRegistration> createState() =>
      _DocumentCloseRegistrationState();
}

class _DocumentCloseRegistrationState extends State<DocumentCloseRegistration> {
  DocumentCloseCoordinator? _coordinator;
  void Function()? _unregister;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final coordinator = DocumentCloseScope.maybeOf(context);
    if (identical(coordinator, _coordinator)) return;
    _unregister?.call();
    _coordinator = coordinator;
    _unregister = coordinator?.register(
      key: this,
      revision: () => widget.revision(),
      prepare: () => widget.prepare(),
    );
  }

  @override
  void dispose() {
    _unregister?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
